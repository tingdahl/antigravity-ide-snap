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
- Direct launch: the app launches directly via
  `usr/share/antigravity-ide/bin/antigravity-ide --no-sandbox` with standard
  desktop environment variables. No custom wrapper script or `LD_LIBRARY_PATH`
  overrides are needed.

## Host toolchain, graphics, and why core22 works

- Under classic confinement, the app executes in the host's mount namespace and uses
  the host's dynamic linker, GLIBC, and desktop/graphics stack (GTK, Mesa/DRI, X11/Wayland).
- We do **not** use `build-attributes: [enable-patchelf]`. The upstream binaries
  retain their original ELF interpreter and `$ORIGIN` rpaths and resolve against
  the host system, exactly like the upstream tarball.
- When strict confinement (or early classic setups) used `enable-patchelf`, the ELF
  interpreter was patched to point to the base snap's glibc, requiring `core24`
  because the upstream binary needed `GLIBC_2.38+` (while `core22` is glibc 2.35).
  Without `enable-patchelf`, this limitation disappears and `base: core22` works fine.
- Staged packages are kept minimal: only `ca-certificates` and `locales-all` are
  bundled. We avoid bundling GTK, Mesa, or WebKit libraries, avoiding library
  mismatches with host DRI modules.

## Desktop entry / icon

- Multi-app snaps do not expose a bare `/snap/bin/<snap-name>` command. Desktop
  `Exec=` entries must target an exported app command such as
  `<snap-name>.<app-name>`, or snapd may strip the `Exec` field.
- Use `Icon=${SNAP}/meta/gui/<name>.png` (snapd expands `${SNAP}`). Bare icon
  names are not registered in the system icon theme.
- The file in `meta/gui/` must match the basename in the `Icon=` field.
