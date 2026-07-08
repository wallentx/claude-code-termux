#!/usr/bin/env python3
"""Decide whether a CI job should run from changed paths."""

from __future__ import annotations

import os
import subprocess
import sys


ARTIFACT_PATHS = {
    ".github/scripts/ci-should-run.py",
    ".github/scripts/compat-test.sh",
    ".github/scripts/package-release.sh",
    ".github/workflows/package-release.yml",
    ".github/workflows/termux-compat.yml",
    "build.sh",
}

INSTALL_PATHS = {
    ".github/scripts/ci-should-run.py",
    ".github/workflows/install-smoke.yml",
    "install.sh",
}


def emit(name: str, value: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def normalize(path: str) -> str:
    path = path.strip().replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    return path


def changed_paths() -> list[str] | None:
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    if event == "workflow_dispatch":
        return None

    base = os.environ.get("BASE_SHA", "")
    head = os.environ.get("HEAD_SHA", "")
    if not base or not head:
        return None

    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", f"{base}...{head}"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError:
        return None

    return [normalize(line) for line in result.stdout.splitlines() if line.strip()]


def under(path: str, directory: str) -> bool:
    return path == directory or path.startswith(f"{directory}/")


def artifact_path(path: str) -> bool:
    return path in ARTIFACT_PATHS or under(path, "lib")


def install_path(path: str) -> bool:
    return path in INSTALL_PATHS


PREDICATES = {
    "termux-compat": artifact_path,
    "install-smoke": install_path,
}


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in PREDICATES:
        modes = ", ".join(sorted(PREDICATES))
        print(f"usage: {sys.argv[0]} <{modes}>", file=sys.stderr)
        return 2

    paths = changed_paths()
    if paths is None:
        reason = "changed-file metadata unavailable or manual dispatch; running"
        emit("should_run", "true")
        emit("reason", reason)
        print(reason)
        return 0

    matches = sorted(path for path in paths if PREDICATES[sys.argv[1]](path))
    should_run = bool(matches)
    reason = (
        "matched relevant paths: " + ", ".join(matches)
        if should_run
        else "no relevant paths changed"
    )

    emit("should_run", "true" if should_run else "false")
    emit("reason", reason)
    print(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
