# nvidia-reset

Reset NVIDIA graphics drivers on Arch Linux without rebooting — similar to
Windows' Win+Shift+B driver recovery. Unloads and reloads the `nvidia`,
`nvidia_modeset`, `nvidia_drm`, and `nvidia_uvm` kernel modules, bouncing the
display manager around the reload since nothing can hold `/dev/nvidia*` open
while the modules are unloaded.

Originally built for KDE Plasma on Wayland with the `nvidia-open` driver,
where the display manager is `plasmalogin.service` (aliased via the generic
`display-manager.service`). The module names (`nvidia`/`nvidia_modeset`/
`nvidia_drm`/`nvidia_uvm`) are the same across `nvidia`, `nvidia-open`, and
`nvidia-dkms`, so any of those driver packages work as-is. The display
manager handling autodetects and falls back for setups without one — see
below.

## How it works

- **`nvidia-reset.sh`** — root-context worker. Autodetects a display
  manager: if the systemd alias `display-manager.service` resolves, that
  unit is stopped before the reload and restarted after. If it doesn't
  resolve (e.g. a session launched with `startx`/`.xinitrc` from a TTY, or a
  DM that doesn't register the alias), it instead terminates the active
  Wayland/X11 login session directly via `loginctl` — there's nothing to
  auto-restart in that case, so you start your session again manually
  afterward. Either way, it then force-unloads the nvidia modules (falling
  back to `fuser -k` on stuck GPU clients after 5 failed attempts, giving up
  after 10) and reloads them.
- **`nvidia-reset.conf`** — installed to `/etc/nvidia-reset.conf`. Lets you
  override the detected display manager unit (`DM_UNIT=sddm.service`) for
  setups where the alias resolves to the wrong thing, and holds the one-shot
  autologin opt-in described below.
- **`nvidia-reset.service`** — a oneshot systemd unit that runs the worker
  script as root.
- **`nvidia-reset`** — the trigger binary, meant to be bound to a keyboard
  shortcut. With no arguments it starts the service with `--no-block` and
  returns immediately, since it must not run inside the graphical session's
  process tree — that session gets torn down as part of the reset, which
  would kill the trigger mid-flight if it lived there. It also takes a
  couple of setup subcommands, covered below.
- **`99-nvidia-reset.rules`** — a polkit rule letting an active, local member
  of the `wheel` group start/stop *only* `nvidia-reset.service` without a
  password prompt, so the shortcut doesn't need `sudo`. Scoped to this one
  unit on purpose.

## Getting your session back

A reset tears the whole graphical session down — the display manager (or
your Wayland/X11 session directly, if you have no display manager) has to
fully release the GPU before the kernel modules can unload, and nothing can
hold `/dev/nvidia*` open while that happens. That's a real difference from
Windows' driver-recovery, which resets the GPU without tearing down the
desktop session at all — there's no Linux equivalent that hands a live
session back intact. What's realistic instead is shrinking the gap between
"driver's back" and "you're back at your desktop":

- **One-shot autologin** (opt-in, off by default) skips the login prompt
  when the display manager comes back up, so the reset resolves to a
  password-free flicker instead of a full re-login. Enable it once with:

  ```bash
  nvidia-reset --enable-autologin
  ```

  This asks for authentication (via `pkexec`) because it's toggling a
  system-wide setting — but that's the only time you'll be prompted. Once
  enabled, each individual reset stays one-shot: nvidia-reset writes the
  autologin config for whoever was logged in right before the display
  manager stops, and removes it again as soon as that session reappears (or
  after a ~30s timeout if it doesn't), so ordinary logins still ask for a
  password. Turn it back off with `nvidia-reset --disable-autologin`.

  Supported for **sddm**, **gdm**, **lightdm**, and **plasmalogin**
  (KDE's own login manager) — unrecognized display managers are left alone
  and just fall back to a normal login prompt. **greetd** needs one extra
  thing: since it has no notion of a user's "last session" to fall back to,
  set `AUTOLOGIN_GREETD_COMMAND` in `/etc/nvidia-reset.conf` to whatever
  command your greeter would normally launch for you (e.g. `Hyprland` or
  `sway`).

  Caveat: on lightdm and greetd, autologin lands you in whatever session is
  configured as the default for that user/seat, which may not be the exact
  session you were previously running if you normally pick between several.
  sddm and gdm both fall back to your last-used session automatically;
  plasmalogin gets the session matched from your currently active one at
  reset time (falling back to the first available session file, or skipping
  autologin entirely, if none match).

- **Session restore** gets your open apps to reopen automatically, which is
  a property of your desktop environment, not of nvidia-reset. Where your
  DE supports it, turn it on with:

  ```bash
  nvidia-reset --enable-session-restore
  ```

  This runs as you, no authentication needed — it's just flipping your own
  desktop config (`~/.config/ksmserverrc` on KDE Plasma, the
  `xfce4-session` `SaveOnExit` setting on XFCE). GNOME and most other
  desktops don't support session restore upstream at all, so there's
  nothing for this to turn on there — apps will need to be reopened by
  hand. If your DE isn't KDE or XFCE, check its own settings for anything
  like "restore session on login."

## Install

```bash
makepkg -si
```

Installs:

| Source | Destination |
|---|---|
| `nvidia-reset.sh` | `/usr/lib/nvidia-reset/nvidia-reset.sh` |
| `nvidia-reset` | `/usr/bin/nvidia-reset` |
| `nvidia-reset.service` | `/usr/lib/systemd/system/nvidia-reset.service` |
| `99-nvidia-reset.rules` | `/usr/share/polkit-1/rules.d/99-nvidia-reset.rules` |
| `nvidia-reset.conf` | `/etc/nvidia-reset.conf` |

## Usage

Bind a keyboard shortcut (e.g. in KDE System Settings) to run:

```bash
nvidia-reset
```

Your screen will go black for a few seconds while the display manager
restarts and the driver reloads.

## Dependencies

`systemd`, `polkit`, `psmisc` (for `fuser`), `kmod`.

## Caveats

- Anything with an open handle to the GPU (games, browsers with hardware
  acceleration, video players) will be killed when its session is torn down
  — one-shot autologin and session restore shrink the *getting back* part,
  they don't preserve app state through the reset itself.
- If `nvidia-reset.sh` is interrupted after arming one-shot autologin but
  before it cleans up (e.g. power loss mid-reset), the display manager could
  be left with autologin still enabled, or a stray `.nvidia-reset.bak` file
  next to its config (gdm, greetd, plasmalogin). Both the EXIT trap and the
  ~30s reappearance timeout are meant to make that unlikely, but if you
  suspect it happened, check `/etc/sddm.conf.d/99-nvidia-reset-autologin.conf`,
  `/etc/gdm/custom.conf(.nvidia-reset.bak)`,
  `/etc/lightdm/lightdm.conf.d/60-nvidia-reset-autologin.conf`,
  `/etc/greetd/config.toml(.nvidia-reset.bak)`, or
  `/etc/plasmalogin.conf(.nvidia-reset.bak)` for your display manager.
- Not a substitute for fixing an actually-crashed/hung driver — this is for
  recovering a wedged display session without a full reboot.

## Why

I have an issue with one of my monitors that causes it to sometimes have a
vertical line on the screen that scrunches some pixels together. The fix for
this on windows was either rebooting the monitor (sometimes several times)
or resetting the graphics driver (which consistently fixes it the first time
every time). I wanted something similar on my arch setup and this was as
close as I could easily get. A true suspend/resume of the display manager
session isn't really possible on Linux — the driver reload requires every
GPU client to fully release the device, which the Windows model doesn't —
but one-shot autologin and desktop session restore close most of the gap.
