# idle-shutdown

Idle-based VM auto-shutdown helper (SSH/RDP aware) with Debian packaging.

## Release From This Folder

Run all checks and build smoke-tested `.deb` packages for both `amd64` and `arm64`,
then create/reuse an annotated release tag:

```bash
make release
```

Build only one architecture:

```bash
make DEB_ARCH=amd64 deb-build
make DEB_ARCH=arm64 deb-build
```

Smoke test package payload:

```bash
make DEB_ARCH=amd64 deb-smoke
```

## Notes

- Debian packaging in this folder is self-contained.
- Runtime assets are sourced from local files under `assets/`, `systemd/`, and `idle-shutdown.sh`.
