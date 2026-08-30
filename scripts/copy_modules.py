#!/usr/bin/env python3
"""Copy a kernel module dependency closure and its declared firmware."""

from __future__ import annotations

import argparse
import glob
from pathlib import Path
import shutil
import subprocess
import sys


def module_name(path: str) -> str:
    name = Path(path).name
    for suffix in (".zst", ".xz", ".gz"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
    if name.endswith(".ko"):
        name = name[:-3]
    return name.replace("-", "_")


def copy_with_symlink(source: Path, destination: Path, root: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        target = source.readlink()
        destination.unlink(missing_ok=True)
        destination.symlink_to(target)
        resolved = source.resolve()
        try:
            relative = resolved.relative_to(root)
        except ValueError:
            return
        copy_with_symlink(resolved, destination.parents[len(source.relative_to(root).parts) - 1] / relative, root)
    elif source.is_file():
        shutil.copy2(source, destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("modules", nargs="+")
    args = parser.parse_args()

    root = args.root.resolve()
    source_tree = root / "lib/modules" / args.kernel
    destination_tree = args.dest / "lib/modules" / args.kernel
    dep_file = source_tree / "modules.dep"
    if not dep_file.is_file():
        print(f"Missing {dep_file}", file=sys.stderr)
        return 1

    deps: dict[str, list[str]] = {}
    paths_by_name: dict[str, str] = {}
    for line in dep_file.read_text(encoding="utf-8", errors="replace").splitlines():
        path, _, remainder = line.partition(":")
        deps[path] = remainder.split()
        paths_by_name[module_name(path)] = path

    builtin_names: set[str] = set()
    builtin_file = source_tree / "modules.builtin"
    if builtin_file.exists():
        builtin_names = {
            module_name(line.strip())
            for line in builtin_file.read_text(encoding="utf-8", errors="replace").splitlines()
            if line.strip()
        }

    softdeps: dict[str, list[str]] = {}
    softdep_file = source_tree / "modules.softdep"
    if softdep_file.exists():
        for line in softdep_file.read_text(encoding="utf-8", errors="replace").splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[0] == "softdep":
                softdeps[fields[1].replace("-", "_")] = [
                    item.replace("-", "_")
                    for item in fields[2:]
                    if item not in {"pre:", "post:"}
                ]

    selected_paths: set[str] = set()
    missing: list[str] = []

    def add_name(name: str) -> None:
        normalized = name.replace("-", "_")
        path = paths_by_name.get(normalized)
        if path is None:
            if normalized not in builtin_names and normalized not in missing:
                missing.append(normalized)
            return
        add_path(path)
        for soft in softdeps.get(normalized, []):
            add_name(soft)

    def add_path(path: str) -> None:
        if path in selected_paths:
            return
        selected_paths.add(path)
        for dependency in deps.get(path, []):
            add_path(dependency)

    for requested in args.modules:
        add_name(requested)

    for relative in sorted(selected_paths):
        source = source_tree / relative
        destination = destination_tree / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    firmware_names: set[str] = set()
    copied_names = sorted({module_name(path) for path in selected_paths})
    for name in copied_names:
        result = subprocess.run(
            ["modinfo", "-b", str(root), "-k", args.kernel, "-F", "firmware", name],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode == 0:
            firmware_names.update(line.strip() for line in result.stdout.splitlines() if line.strip())

    firmware_root = root / "lib/firmware"
    for firmware in sorted(firmware_names):
        # A few drivers declare wildcard firmware names.
        matches = glob.glob(str(firmware_root / firmware))
        for match in matches:
            source = Path(match)
            relative = source.relative_to(firmware_root)
            destination = args.dest / "lib/firmware" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if source.is_symlink():
                target = source.readlink()
                destination.unlink(missing_ok=True)
                destination.symlink_to(target)
                resolved = source.resolve()
                if resolved.is_file() and resolved.is_relative_to(firmware_root):
                    resolved_relative = resolved.relative_to(firmware_root)
                    resolved_destination = args.dest / "lib/firmware" / resolved_relative
                    resolved_destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(resolved, resolved_destination)
            elif source.is_file():
                shutil.copy2(source, destination)

    print(f"Copied {len(selected_paths)} modules and {len(firmware_names)} declared firmware entries.")
    if missing:
        print("Optional modules built-in or unavailable: " + ", ".join(sorted(missing)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
