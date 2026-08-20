# Packaging notes

Verified findings and gotchas for packaging Antigravity IDE as a
**classic**-confinement snap. Kept in the repo so they persist across machines
and contributors.

## Confinement

- This snap uses **classic** confinement. The Electron app and its agents run
  with the same access to the host filesystem, tools and compilers as a
  normally installed editor.
- **Strict confinement was tried and abandoned.** It required stacking
  workarounds (the `gnome` extension for a confinement-correct gdk-pixbuf,
  Wayland/portal juggling so the file picker saw the real home, an
  `nss_wrapper` shim for LDAP/SSSD accounts, avoiding staged `xdg-utils` so
  OAuth sign-in worked) and still broke on the `home`-interface hidden-file
  rule: the IDE stores config in `~/.antigravity-ide`, which strict AppArmor
  denies. Classic sidesteps all of it.
- The launcher stays lean: `--no-sandbox` plus one `LD_LIBRARY_PATH` export. No
  ozone flags or portal env are needed under classic. The `LD_LIBRARY_PATH` is
  required, though — see "Graphics / mesa" below.

## Graphics / mesa (the startup crash)

- Symptom: immediate `SIGSEGV` on launch inside `gbm_create_device` →
  `libgallium*.so`. Happens even with `--disable-gpu` (Chromium probes GBM
  early).
- Root cause: the GTK/webkit stage-packages transitively pull the whole
  mesa/GL/GBM/DRM stack into the snap, but mesa's DRI driver module
  (`/usr/lib/x86_64-linux-gnu/gbm/dri_gbm.so`) always loads from the **host**.
  A bundled `libgbm`/`libgallium` mixed with the host DRI module crashes — even
  when both are the exact same Ubuntu version.
- Fix: do **not** ship the graphics stack; use the host's (consistent by
  construction under classic). `snap/snapcraft.yaml` `prime:`-excludes
  `usr/lib/x86_64-linux-gnu/{dri,gbm,libEGL*,libGLESv2*,libGL.so*,`
  `libGLdispatch*,libGLX*,libgallium*,libgbm*,libdrm*,libwayland-egl*,`
  `libxcb-dri3*,libxcb-glx*}`, and the launcher sets
  `LD_LIBRARY_PATH=$SNAP/usr/lib/<triplet>:$APPDIR:/usr/lib/<triplet>:/lib/<triplet>`.
  Bundled libs win via rpath + the leading snap paths; the excluded mesa libs
  resolve from the host tail.
- Note: snapd scrubs `LD_*` from the outer environment of `snap run`, so
  `LD_LIBRARY_PATH` must be exported **inside** the launch script.

## Base and toolchain

- `core24` base is glibc 2.39. The upstream Antigravity Electron binary
  requires GLIBC_2.38+ (the ELF interpreter is patched to the base's linker via
  `enable-patchelf`), so `core22` (glibc 2.35) does **not** work.
- `core26` cannot be built on an Ubuntu 24.04 host.
- `core24` requires the `platforms:` stanza, not `architectures:`.
- On core24 several runtime packages carry the `t64` suffix
  (`libasound2t64`, `libgtk-3-0t64`, `libatk1.0-0t64`,
  `libatk-bridge2.0-0t64`).

## Desktop entry / icon

- Multi-app snaps do not expose a bare `/snap/bin/<snap-name>` command. Desktop
  `Exec=` entries must target an exported app command such as
  `<snap-name>.<app-name>`, or snapd may strip the `Exec` field.
- Use `Icon=${SNAP}/meta/gui/<name>.png` (snapd expands `${SNAP}`). Bare icon
  names are not registered in the system icon theme.
- The file in `meta/gui/` must match the basename in the `Icon=` field.
