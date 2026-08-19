# AGENTS.md

This repository packages **Antigravity IDE** as a strictly confined snap.

Before changing packaging (`snap/snapcraft.yaml`) or the runtime wrapper
(`scripts/antigravity-ide-launch`), read **[docs/packaging-notes.md](docs/packaging-notes.md)**.
It captures verified, non-obvious constraints and the reasons behind current
choices (core24/GLIBC requirement, the `gnome` extension fix for the
gdk-pixbuf confinement crash, the `home`-interface hidden-file restriction, the
Wayland/portal file-picker behaviour, and the `xdg-open` sign-in fix).

Key facts:
- Base is `core24`; `core22` and `core26` do not work here (see notes).
- Use the `gnome` extension for the GTK stack — do not hand-stage GTK/gdk-pixbuf.
- Build with `snapcraft pack`; install locally with
  `snap install ./antigravity-ide-snap_*_amd64.snap --dangerous`.
