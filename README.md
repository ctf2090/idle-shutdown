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

- This packaging flow currently extracts some assets from:
  `../gce-lubuntu-noble/cloud-init.yaml`
- Override source path when needed:

```bash
make CLOUD_INIT_PATH=/path/to/cloud-init.yaml release
```
