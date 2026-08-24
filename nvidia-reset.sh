#!/usr/bin/env bash
# Root-context worker: unload/reload the NVIDIA kernel modules, bouncing the
# display manager around it since nothing can hold /dev/nvidia* open while
# the modules are unloaded. Falls back to terminating the active graphical
# session directly on setups with no display manager (e.g. startx/.xinitrc).
set -uo pipefail

log() { echo "[nvidia-reset] $*"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# Optional overrides from /etc/nvidia-reset.conf -- see that file for what
# each of these does.
DM_UNIT=""
ONESHOT_AUTOLOGIN="no"
AUTOLOGIN_GREETD_COMMAND=""
[ -f /etc/nvidia-reset.conf ] && . /etc/nvidia-reset.conf

if [ -z "$DM_UNIT" ] && systemctl cat display-manager.service &>/dev/null; then
    DM_UNIT="display-manager.service"
fi

# The systemd alias resolves fine for stop/start, but for figuring out
# *which* display manager we're actually dealing with we need the real unit
# it points to -- "display-manager" itself isn't a recognizable DM name.
resolve_dm_name() {
    local id
    id="$(systemctl show -p Id --value "$1" 2>/dev/null)"
    printf '%s' "${id%.service}"
}

# Whichever local session (if any) is active right before the display
# manager goes down -- used both to target one-shot autologin and, later, to
# know whose session to wait for once the display manager is back. Prints
# "user type desktop" (desktop may be empty) on one line.
active_session_info() {
    local session type
    while read -r session _; do
        type="$(loginctl show-session "$session" -p Type --value 2>/dev/null)"
        case "$type" in
        wayland | x11)
            printf '%s %s %s\n' \
                "$(loginctl show-session "$session" -p Name --value 2>/dev/null)" \
                "$type" \
                "$(loginctl show-session "$session" -p Desktop --value 2>/dev/null)"
            return 0
            ;;
        esac
    done < <(loginctl list-sessions --no-legend)
    return 1
}

# Picks the .desktop session file matching $1 (wayland|x11) and, if there's
# more than one candidate, prefers one whose DesktopNames matches $2 (the
# logind "Desktop" property, e.g. "KDE"). Used because autologin configs
# that take a session need a real .desktop filename, and we'd rather skip
# autologin than guess wrong and drop you into an unintended desktop.
pick_session_desktop_file() {
    local type="$1" hint="${2,,}" dir entry match="" names
    case "$type" in
    wayland) dir=/usr/share/wayland-sessions ;;
    x11) dir=/usr/share/xsessions ;;
    *) return 1 ;;
    esac
    [ -d "$dir" ] || return 1
    for entry in "$dir"/*.desktop; do
        [ -e "$entry" ] || continue
        [ -z "$match" ] && match="$(basename "$entry")"
        names="$(sed -n 's/^DesktopNames=//p' "$entry" | head -1)"
        if [ -n "$hint" ] && [ -n "$names" ] && [[ ",${names,,}," == *",${hint},"* ]]; then
            basename "$entry"
            return 0
        fi
    done
    [ -n "$match" ] && printf '%s' "$match" && return 0
    return 1
}

wait_for_user_session() {
    local user="$1" session tries=0
    while [ "$tries" -lt 30 ]; do
        while read -r session _; do
            [ "$(loginctl show-session "$session" -p Name --value 2>/dev/null)" = "$user" ] || continue
            case "$(loginctl show-session "$session" -p Type --value 2>/dev/null)" in
            wayland | x11) return 0 ;;
            esac
        done < <(loginctl list-sessions --no-legend)
        sleep 1
        tries=$((tries + 1))
    done
    return 1
}

# Set on success by setup_autologin() below; run by the EXIT trap so a
# one-shot autologin config never survives a failure partway through, and
# also run explicitly (with this cleared right after) once the user's
# session reappears in the normal path.
AUTOLOGIN_CLEANUP=""
trap '[ -n "$AUTOLOGIN_CLEANUP" ] && eval "$AUTOLOGIN_CLEANUP"' EXIT

# Writes a one-shot autologin config for user $2 (session type $3, logind
# "Desktop" hint $4) into whichever display manager $1 names, remembering
# how to undo it in $AUTOLOGIN_CLEANUP. Unrecognized display managers are
# left alone -- the caller falls back to a normal login prompt in that case.
setup_autologin() {
    local dm="$1" user="$2" type="$3" desktop_hint="$4" f session_file
    case "$dm" in
    sddm)
        f=/etc/sddm.conf.d/99-nvidia-reset-autologin.conf
        mkdir -p /etc/sddm.conf.d
        printf '[Autologin]\nUser=%s\n' "$user" >"$f"
        AUTOLOGIN_CLEANUP="rm -f '$f'"
        ;;
    gdm)
        f=/etc/gdm/custom.conf
        [ -f "$f" ] || : >"$f"
        cp -p "$f" "$f.nvidia-reset.bak"
        if grep -q '^\[daemon\]' "$f"; then
            sed -i "/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$user" "$f"
        else
            printf '\n[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$user" >>"$f"
        fi
        AUTOLOGIN_CLEANUP="mv -f '$f.nvidia-reset.bak' '$f'"
        ;;
    lightdm)
        f=/etc/lightdm/lightdm.conf.d/60-nvidia-reset-autologin.conf
        mkdir -p /etc/lightdm/lightdm.conf.d
        printf '[Seat:*]\nautologin-user=%s\n' "$user" >"$f"
        AUTOLOGIN_CLEANUP="rm -f '$f'"
        ;;
    greetd)
        [ -n "$AUTOLOGIN_GREETD_COMMAND" ] || {
            log "ONESHOT_AUTOLOGIN is set but AUTOLOGIN_GREETD_COMMAND is empty, skipping autologin"
            return 1
        }
        f=/etc/greetd/config.toml
        [ -f "$f" ] || return 1
        cp -p "$f" "$f.nvidia-reset.bak"
        # greetd only honors initial_session for the next login, but strip
        # any stale table first since duplicate TOML tables are invalid.
        awk '/^\[initial_session\]/{skip=1;next} /^\[/{skip=0} !skip' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
        printf '\n[initial_session]\ncommand = "%s"\nuser = "%s"\n' "$AUTOLOGIN_GREETD_COMMAND" "$user" >>"$f"
        AUTOLOGIN_CLEANUP="mv -f '$f.nvidia-reset.bak' '$f'"
        ;;
    plasmalogin)
        session_file="$(pick_session_desktop_file "$type" "$desktop_hint")" || {
            log "plasmalogin: couldn't find a matching session file for $type/$desktop_hint, skipping autologin"
            return 1
        }
        f=/etc/plasmalogin.conf
        [ -f "$f" ] || : >"$f"
        cp -p "$f" "$f.nvidia-reset.bak"
        # Strip any existing [Autologin] section (KCM-set or stale) before
        # writing ours, same reasoning as greetd above.
        awk '/^\[Autologin\]/{skip=1;next} /^\[/{skip=0} !skip' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
        printf '\n[Autologin]\nUser=%s\nSession=%s\n' "$user" "$session_file" >>"$f"
        AUTOLOGIN_CLEANUP="mv -f '$f.nvidia-reset.bak' '$f'"
        ;;
    *)
        log "ONESHOT_AUTOLOGIN is set but '$dm' isn't a recognized display manager, skipping autologin"
        return 1
        ;;
    esac
}

AUTOLOGIN_USER=""
if [ -n "$DM_UNIT" ]; then
    if [ "$ONESHOT_AUTOLOGIN" = "yes" ]; then
        session_info="$(active_session_info || true)"
        if [ -n "$session_info" ]; then
            read -r AUTOLOGIN_USER session_type session_desktop <<<"$session_info"
            if setup_autologin "$(resolve_dm_name "$DM_UNIT")" "$AUTOLOGIN_USER" "$session_type" "$session_desktop"; then
                log "one-shot autologin armed for $AUTOLOGIN_USER"
            else
                AUTOLOGIN_USER=""
            fi
        else
            log "ONESHOT_AUTOLOGIN is set but no active local session was found, skipping autologin"
        fi
    fi
    log "stopping display manager ($DM_UNIT)..."
    systemctl stop "$DM_UNIT" || die "failed to stop $DM_UNIT"
else
    log "no display manager detected, terminating active graphical session(s)..."
    while read -r session _; do
        case "$(loginctl show-session "$session" -p Type --value 2>/dev/null)" in
            wayland|x11) loginctl terminate-session "$session" 2>/dev/null || true ;;
        esac
    done < <(loginctl list-sessions --no-legend)
fi

# harmless no-ops if not running; both hold an open handle to the GPU when
# they are, and neither gets caught cleanly by the fuser fallback below
# since they're long-running daemons rather than one-off GPU clients.
systemctl stop nvidia-persistenced.service 2>/dev/null || true
systemctl stop nvidia-cuda-mps-control.service 2>/dev/null || true

unload() {
    local mod="$1" tries=0
    while lsmod | grep -q "^${mod} "; do
        modprobe -r "$mod" 2>/dev/null && return 0
        tries=$((tries + 1))
        if [ "$tries" -eq 5 ]; then
            log "$mod still busy, forcing remaining GPU clients off..."
            fuser -k /dev/nvidia* /dev/dri/card* /dev/dri/renderD* 2>/dev/null || true
        fi
        if [ "$tries" -ge 10 ]; then
            die "could not unload $mod after repeated attempts"
        fi
        sleep 0.5
    done
}

log "unloading nvidia kernel modules..."
unload nvidia_drm
unload nvidia_modeset
unload nvidia_uvm
unload nvidia

log "reloading nvidia kernel modules..."
modprobe nvidia || die "failed to load nvidia"
modprobe nvidia_uvm || die "failed to load nvidia_uvm"
modprobe nvidia_modeset || die "failed to load nvidia_modeset"
modprobe nvidia_drm || die "failed to load nvidia_drm"

if [ -n "$DM_UNIT" ]; then
    log "restarting display manager ($DM_UNIT)..."
    systemctl start "$DM_UNIT" || die "failed to start $DM_UNIT"
else
    log "no display manager to restart — start your graphical session manually."
fi

if [ -n "$AUTOLOGIN_CLEANUP" ]; then
    log "waiting for $AUTOLOGIN_USER's session before clearing one-shot autologin..."
    wait_for_user_session "$AUTOLOGIN_USER" || log "timed out waiting for $AUTOLOGIN_USER's session, clearing one-shot autologin anyway"
    eval "$AUTOLOGIN_CLEANUP"
    AUTOLOGIN_CLEANUP=""
fi

log "done."
