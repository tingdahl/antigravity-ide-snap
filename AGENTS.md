# AGENTS.md

This repository packages **Antigravity IDE** as a **classic**-confinement snap.

Before changing packaging (`snap/snapcraft.yaml`), read
**[docs/packaging-notes.md](docs/packaging-notes.md)**. It captures verified,
non-obvious constraints and the reasons behind current choices (classic confinement,
`core24` base with multi-arch `platforms:`, and desktop-entry/icon rules).

Key facts:
- Confinement is `classic`: the IDE and its agents share the host's tools,
  compilers and files, like a normally installed editor. Strict confinement was
  tried and abandoned — see the packaging notes.
- Base is `core24` with `platforms:` for `amd64` and `arm64`: under classic
  confinement without `enable-patchelf`, the upstream Electron binaries keep
  their original ELF interpreter and resolve GLIBC and graphics libraries against
  the host system. `core24` enables native `--destructive-mode --platform <arch>`
  builds on GitHub Actions `ubuntu-24.04` and `ubuntu-24.04-arm` runners.
- Build locally with `snapcraft pack` (or `sudo snapcraft pack --destructive-mode --platform <arch>`
  on Ubuntu 24.04); install locally with
  `snap install ./antigravity-ide-snap_*_amd64.snap --dangerous --classic`.
