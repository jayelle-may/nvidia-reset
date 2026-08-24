#!/usr/bin/env bash
# Root-context worker: unload/reload the NVIDIA kernel modules, bouncing the
# display manager around it since nothing can hold /dev/nvidia* open while
# the modules are unloaded.
set -uo pipefail

log() { echo "[nvidia-reset] $*"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

DM_UNIT="display-manager.service"

log "stopping display manager ($DM_UNIT)..."
systemctl stop "$DM_UNIT" || die "failed to stop $DM_UNIT"

# harmless no-op if not running; holds an open handle to the GPU when it is
systemctl stop nvidia-persistenced.service 2>/dev/null || true

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

log "restarting display manager ($DM_UNIT)..."
systemctl start "$DM_UNIT" || die "failed to start $DM_UNIT"

log "done."
