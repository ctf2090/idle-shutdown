# idle-shutdown

Idle-based VM auto-shutdown helper (SSH/RDP aware) with Debian packaging.

## Release From This Folder

Run all checks and build a smoke-tested architecture-independent (`all`) `.deb`,
then create/reuse an annotated release tag:

```bash
make release
```

Build package:

```bash
make DEB_ARCH=all deb-build
```

Smoke test package payload:

```bash
make DEB_ARCH=all deb-smoke
```

## Notes

- Debian packaging in this folder is self-contained.
- Runtime assets are sourced from local files under `assets/`, `systemd/`, and `idle-shutdown.sh`.
