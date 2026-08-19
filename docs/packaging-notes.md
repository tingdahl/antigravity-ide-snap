# Packaging notes

Verified findings and gotchas for packaging Antigravity IDE as a strictly
confined snap. Kept in the repo so they persist across machines and
contributors.

## Base and toolchain

- `core24` base is glibc 2.39. The upstream Antigravity Electron binary
  requires GLIBC_2.38+, so `core22` (glibc 2.35) does **not** work.
- `core26` cannot be built on an Ubuntu 24.04 host.
- `core24` requires the `platforms:` stanza, not `architectures:`.

## GTK / gdk-pixbuf under strict confinement

- Symptom: the app aborts on the first GTK icon render with
  `Gtk:ERROR ... Failed to load .../image-missing.png: Unrecognized image file
  format`, and `gdk-pixbuf-thumbnailer` fails on *any* PNG with
  "Couldn't recognize the image file format".
- Root cause: manually staging `gtk3` / `gdk-pixbuf` does not work under strict
  confinement. PNG/JPEG are **built-in** loaders in Ubuntu's `libgdk_pixbuf`
  (not external `.so`, not in `loaders.cache`), and those built-ins fail to
  register under confinement. Verified: the snap's own
  `gdk-pixbuf-thumbnailer` + `libgdk_pixbuf` (byte-identical to the host copy)
  decodes PNG fine when run **unconfined** via its rpath, but fails under
  `snap run` even with a clean `env -i` and **no** pixbuf-related AppArmor
  denial. Confinement is the sole differentiator.
- Fix: use the **`gnome` extension** (gnome-46-2404 platform snap) instead of
  hand-staging GTK. It provides a confinement-correct
  GTK/gdk-pixbuf/mesa/glib/icon/theme/fontconfig stack plus command-chain env.
  This is what VS Code's own snap does. After switching, remove staged
  `libgtk-3-0` / `libgdk-pixbuf*` / `libglib2.0*` / mesa / themes / icons, the
  pixbuf/schema `override-prime`, and the GTK/GDK env exports from the launcher.
- The `gnome` extension auto-adds these plugs — do not list them manually:
  `desktop`, `desktop-legacy`, `wayland`, `x11`, `opengl`, `gsettings`.

## Desktop integration quirks

- **File dialog opened in the snap's private HOME** (`~/snap/<name>/<rev>`)
  instead of the real home. This cannot be fixed by exporting
  `HOME=$SNAP_REAL_HOME`: the `home` interface AppArmor rule
  (`owner @{HOME}/[^s.]** rwklix`) excludes top-level hidden dirs, and the app
  stores config in `~/.antigravity-ide` (hidden), so writes to the real home
  would be denied. `GTK_USE_PORTAL=1` alone did not switch this Electron's
  classic GTK chooser.
  - Fix: the launcher prefers native Wayland when `$WAYLAND_DISPLAY` is set.
    Under Ozone/Wayland, Electron uses the xdg-desktop-portal file picker,
    which runs unconfined and shows the real home. X11 is the fallback
    (`--disable-gpu`). Escape hatches: `ANTIGRAVITY_FORCE_X11=1`,
    `ANTIGRAVITY_DISABLE_GPU=1`.
- **Sign In (OAuth) did nothing** because staging `xdg-utils` placed a
  `$SNAP/usr/bin/xdg-open` first in `PATH`, shadowing snapd's portal shim
  `/usr/bin/xdg-open` (`exec snapctl user-open "$@"`). Fix: do **not** stage
  `xdg-utils`; let snapd's shim open URLs in the host browser.
- Keyring/secret storage needs the `password-manager-service` plug connected:
  `snap connect antigravity-ide-snap:password-manager-service`.

## Desktop entry / icon

- Multi-app snaps do not expose a bare `/snap/bin/<snap-name>` command. Desktop
  `Exec=` entries must target an exported app command such as
  `<snap-name>.<app-name>`, or snapd may strip the `Exec` field.
- Use `Icon=${SNAP}/meta/gui/<name>.png` (snapd expands `${SNAP}`). Bare icon
  names are not registered in the system icon theme.
- The file in `meta/gui/` must match the basename in the `Icon=` field.
