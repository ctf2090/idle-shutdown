#!/usr/bin/env python3
"""Export idle-shutdown assets from cloud-init write_files into a staging tree."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

import yaml


CLOUD_INIT_TARGETS = {
    "/etc/default/idle-shutdown": ("etc/default/idle-shutdown", 0o644),
    "/etc/profile.d/idle-terminal-activity.sh": ("etc/profile.d/idle-terminal-activity.sh", 0o644),
    "/etc/xdg/autostart/idle-rdp-input-watch.desktop": ("etc/xdg/autostart/idle-rdp-input-watch.desktop", 0o644),
    "/usr/local/sbin/idle-rdp-input-watch.sh": ("usr/local/sbin/idle-rdp-input-watch.sh", 0o755),
    "/usr/local/sbin/idle-rdp-disconnect-watch.sh": (
        "usr/local/sbin/idle-rdp-disconnect-watch.sh",
        0o755,
    ),
    "/usr/local/sbin/idle-ssh-disconnect-watch.sh": ("usr/local/sbin/idle-ssh-disconnect-watch.sh", 0o755),
}

LOCAL_FILE_TARGETS = {
    "/etc/systemd/system/idle-shutdown.service": (
        "etc/systemd/system/idle-shutdown.service",
        0o644,
        "systemd/idle-shutdown.service",
    ),
    "/etc/systemd/system/idle-shutdown.timer": (
        "etc/systemd/system/idle-shutdown.timer",
        0o644,
        "systemd/idle-shutdown.timer",
    ),
    "/etc/systemd/system/idle-rdp-disconnect-watch.service": (
        "etc/systemd/system/idle-rdp-disconnect-watch.service",
        0o644,
        "systemd/idle-rdp-disconnect-watch.service",
    ),
    "/etc/systemd/system/idle-ssh-disconnect-watch.service": (
        "etc/systemd/system/idle-ssh-disconnect-watch.service",
        0o644,
        "systemd/idle-ssh-disconnect-watch.service",
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloud-init", required=True, help="Path to cloud-init.yaml")
    parser.add_argument("--idle-script", required=True, help="Path to idle-shutdown.sh")
    parser.add_argument("--out-dir", required=True, help="Output root directory")
    parser.add_argument(
        "--git-rev",
        default="",
        help="Optional value written to etc/idle-shutdown-git-rev inside output tree",
    )
    return parser.parse_args()


def ensure_newline(content: str) -> str:
    if content and not content.endswith("\n"):
        return content + "\n"
    return content


def write_text(path: Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(ensure_newline(content))
    os.chmod(path, mode)


def main() -> int:
    args = parse_args()

    cloud_init_path = Path(args.cloud_init)
    idle_script_path = Path(args.idle_script)
    out_root = Path(args.out_dir)
    script_root = Path(__file__).resolve().parent

    if not cloud_init_path.is_file():
        sys.stderr.write(f"[ERROR] Missing cloud-init file: {cloud_init_path}\n")
        return 2
    if not idle_script_path.is_file():
        sys.stderr.write(f"[ERROR] Missing idle script file: {idle_script_path}\n")
        return 2

    with cloud_init_path.open("r", encoding="utf-8") as f:
        doc = yaml.safe_load(f)

    for _dst_path, (rel, mode, local_rel) in LOCAL_FILE_TARGETS.items():
        src = script_root / local_rel
        if not src.is_file():
            sys.stderr.write(f"[ERROR] Missing local asset file: {src}\n")
            return 2
        write_text(out_root / rel, src.read_text(encoding="utf-8"), mode)

    write_files = doc.get("write_files") or []
    by_path: dict[str, str] = {}
    for entry in write_files:
        if not isinstance(entry, dict):
            continue
        file_path = entry.get("path")
        if file_path in CLOUD_INIT_TARGETS:
            by_path[file_path] = entry.get("content") or ""

    missing = [p for p in CLOUD_INIT_TARGETS if p not in by_path]
    if missing:
        sys.stderr.write("[ERROR] cloud-init.yaml missing write_files entries for:\n")
        for item in missing:
            sys.stderr.write(f"  - {item}\n")
        return 2

    for src_path, content in by_path.items():
        rel, mode = CLOUD_INIT_TARGETS[src_path]
        write_text(out_root / rel, content, mode)

    idle_dst = out_root / "usr/local/sbin/idle-shutdown.sh"
    idle_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(idle_script_path, idle_dst)
    os.chmod(idle_dst, 0o755)

    git_rev = args.git_rev.strip()
    if git_rev:
        write_text(out_root / "etc/idle-shutdown-git-rev", git_rev, 0o644)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
