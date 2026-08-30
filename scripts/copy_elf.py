#!/usr/bin/env python3
"""Copy executables and their ELF shared-library closure from a mounted root."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys

NEEDED = re.compile(r"Shared library: \[(.+?)\]")
INTERPRETER = re.compile(r"Requesting program interpreter: (.+?)\]")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    root = args.root.resolve()
    dest = args.dest.resolve()

    library_index: dict[str, list[Path]] = {}
    for base_name in ("lib", "lib64", "usr/lib"):
        base = root / base_name
        if not base.exists():
            continue
        for candidate in base.rglob("*"):
            if candidate.is_file() or candidate.is_symlink():
                library_index.setdefault(candidate.name, []).append(candidate)

    copied: set[Path] = set()

    def destination_for(source: Path) -> Path:
        return dest / source.relative_to(root)

    def copy_path(source: Path) -> Path:
        try:
            relative = source.relative_to(root)
        except ValueError as error:
            raise RuntimeError(f"refusing path outside source root: {source}") from error
        destination = dest / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            target = source.readlink()
            destination.unlink(missing_ok=True)
            destination.symlink_to(target)
            resolved = source.resolve()
            if resolved.is_file() and resolved.is_relative_to(root):
                # Preserve the lexical link layout. On usrmerged Ubuntu,
                # /lib paths resolve into /usr/lib on the mounted host; copying
                # only that canonical path would leave an initramfs /lib link
                # dangling because /lib is a real staging directory.
                if target.is_absolute():
                    target_destination = dest / str(target).lstrip("/")
                else:
                    target_destination = destination.parent / target
                target_destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(resolved, target_destination)
                return resolved
        elif source.is_file():
            shutil.copy2(source, destination)
        return source.resolve()

    def find_library(name: str) -> Path:
        candidates = library_index.get(name, [])
        if not candidates:
            raise RuntimeError(f"could not resolve shared library {name}")
        candidates.sort(
            key=lambda path: (
                "x86_64-linux-gnu" not in str(path),
                str(path).startswith(str(root / "usr/local")),
                len(str(path)),
            )
        )
        return candidates[0]

    def copy_elf(source: Path) -> None:
        real_source = source.resolve()
        if real_source in copied:
            copy_path(source)
            return
        copy_path(source)
        copied.add(real_source)
        dynamic = subprocess.run(
            ["readelf", "-d", str(real_source)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        program = subprocess.run(
            ["readelf", "-l", str(real_source)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if dynamic.returncode != 0:
            return
        dependencies = NEEDED.findall(dynamic.stdout)
        interpreters = INTERPRETER.findall(program.stdout) if program.returncode == 0 else []
        for interpreter in interpreters:
            copy_elf(root / interpreter.lstrip("/"))
        for dependency in dependencies:
            copy_elf(find_library(dependency))

    try:
        for requested in args.paths:
            source = root / requested.lstrip("/")
            if not source.exists():
                raise RuntimeError(f"required executable does not exist: {requested}")
            copy_elf(source)
    except RuntimeError as error:
        print(f"copy_elf: {error}", file=sys.stderr)
        return 1

    print(f"Copied {len(copied)} executable/library files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
