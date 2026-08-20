# AGENTS.md

This repository packages **Antigravity IDE** as a **classic**-confinement snap.

Before changing packaging (`snap/snapcraft.yaml`) or the runtime wrapper
(`scripts/antigravity-ide-launch`), read **[docs/packaging-notes.md](docs/packaging-notes.md)**.
It captures verified, non-obvious constraints and the reasons behind current
choices (the core24/GLIBC requirement and the desktop-entry/icon rules).

Key facts:
- Confinement is `classic`: the IDE and its agents share the host's tools,
  compilers and files, like a normally installed editor. Strict confinement was
  tried and abandoned — see the packaging notes.
- Base is `core24`; `core22` and `core26` do not work here (see notes).
- Build with `snapcraft pack`; install locally with
  `snap install ./antigravity-ide-snap_*_amd64.snap --dangerous --classic`.
