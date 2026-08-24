# nvidia-reset

Reset NVIDIA graphics drivers on Arch Linux without rebooting — similar to
Windows' Win+Shift+B driver recovery. Unloads and reloads the `nvidia`,
`nvidia_modeset`, `nvidia_drm`, and `nvidia_uvm` kernel modules, bouncing the
display manager around the reload since nothing can hold `/dev/nvidia*` open
while the modules are unloaded.

Built for KDE Plasma on Wayland with the `nvidia-open` driver, where the
display manager is `plasmalogin.service` (aliased via the generic
`display-manager.service`). Should generalize to any setup where
`display-manager.service` resolves correctly, but hasn't been tested beyond
that.

## How it works

- **`nvidia-reset.sh`** — root-context worker. Stops the display manager,
  force-unloads the nvidia modules (falling back to `fuser -k` on stuck GPU
  clients after 5 failed attempts, giving up after 10), reloads them, and
  restarts the display manager.
- **`nvidia-reset.service`** — a oneshot systemd unit that runs the worker
  script as root.
- **`nvidia-reset`** — the trigger binary, meant to be bound to a keyboard
  shortcut. Starts the service with `--no-block` and returns immediately,
  since it must not run inside the graphical session's process tree — that
  session gets torn down as part of the reset, which would kill the trigger
  mid-flight if it lived there.
- **`99-nvidia-reset.rules`** — a polkit rule letting an active, local member
  of the `wheel` group start/stop *only* `nvidia-reset.service` without a
  password prompt, so the shortcut doesn't need `sudo`. Scoped to this one
  unit on purpose.

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
  acceleration, video players) will be killed when its session is torn down.
- Not a substitute for fixing an actually-crashed/hung driver — this is for
  recovering a wedged display session without a full reboot.
