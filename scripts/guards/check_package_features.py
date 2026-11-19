"""Package.swift enables the Swift 7 upcoming features on every target and uses no
experimental features without a decision (D29).

Every SwiftPM target uses a complete literal settings array or a shared constant
holding one. Every native app target configuration enables the same features.
SwiftPM sets Swift 6 mode and experimental features require a same-line decision.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

from swift_source import run, split_swift

REQUIRED = (
    "ExistentialAny",
    "InternalImportsByDefault",
    "MemberImportVisibility",
    "InferIsolatedConformances",
    "NonisolatedNonsendingByDefault",
    "ImmutableWeakCaptures",
)
UPCOMING = re.compile(r"\.enableUpcomingFeature\(")
EXPERIMENTAL = re.compile(r"\.enableExperimentalFeature\(")
MARKER = re.compile(r"guard:allow-experimental\s+D\d+")
LANGUAGE_MODE = re.compile(r"swiftLanguageModes?\s*:\s*\[?\s*\.v6|\.swiftLanguageMode\(\s*\.v6\s*\)")
TARGET = re.compile(r"\.(?:target|executableTarget|testTarget)\(")


SHARED = re.compile(r"(?m)^[ \t]*let\s+(\w+)\s*:\s*\[SwiftSetting\]\s*=\s*\[")
TARGET_SETTINGS = re.compile(r"\bswiftSettings\s*:\s*")
PROJECT = Path("App/SiltaApp.xcodeproj/project.pbxproj")
PBX_FEATURE = re.compile(r"(?:^|\s)-enable-upcoming-feature\s+(\w+)(?=\s|$)")
DELIMITERS = {"(": ")", "[": "]", "{": "}"}


def call_span(code: str, opening: int) -> int:
    """Index just past the balanced delimiter at `opening`."""
    first = code[opening]
    last = DELIMITERS[first]
    depth = 0
    for i in range(opening, len(code)):
        if code[i] == first:
            depth += 1
        elif code[i] == last:
            depth -= 1
            if depth == 0:
                return i + 1
    return len(code)


def enabled_features(raw: str, code: str, start: int, end: int) -> set[str]:
    enabled = set()
    for match in UPCOMING.finditer(code, start, end):
        # Strings are spaces in code, so inspect the arguments in the source.
        literal = re.match(r'\s*"([^"\\]*)"\s*\)', raw[match.end():end])
        if literal:
            enabled.add(literal.group(1))
    return enabled


def target_settings(code: str, start: int, end: int) -> re.Match[str] | None:
    for setting in TARGET_SETTINGS.finditer(code, start, end):
        leading = code[start:setting.start()]
        if all(leading.count(left) == leading.count(right) for left, right in DELIMITERS.items()):
            return setting
    return None


def package_errors(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8")
    code, _ = split_swift(raw)
    raw_lines = raw.split("\n")
    required = set(REQUIRED)
    errors = []

    missing = required - enabled_features(raw, code, 0, len(code))
    for name in sorted(missing):
        errors.append(f'Package.swift: missing .enableUpcomingFeature("{name}")')
    if not LANGUAGE_MODE.search(code):
        errors.append("Package.swift: Swift 6 language mode (.v6) is not set")

    shared = set()
    for match in SHARED.finditer(code):
        finish = call_span(code, match.end() - 1)
        following = code[finish:].lstrip()
        if following and not following.startswith((";", "let ")):
            continue  # require a standalone array literal
        if required <= enabled_features(raw, code, match.end(), finish):
            shared.add(match.group(1))
    declaration_end = -1
    for match in TARGET.finditer(code):
        if match.start() < declaration_end:
            continue  # a .target(name:) dependency nested inside a declaration
        end = declaration_end = call_span(code, match.end() - 1)
        settings = target_settings(code, match.end(), end)
        line = code.count("\n", 0, match.start()) + 1
        if settings is None:
            errors.append(f"Package.swift:{line}: target without swiftSettings")
        elif not missing:
            start = settings.end()
            if code[start:start + 1] == "[":
                finish = call_span(code, start)
                valid = required <= enabled_features(raw, code, start + 1, finish)
                valid = valid and code[finish:end].lstrip()[:1] in (",", ")")
            else:
                name = re.match(r"(\w+)\s*[,)]", code[start:end])
                valid = name is not None and name.group(1) in shared
            if not valid:
                errors.append(f"Package.swift:{line}: target swiftSettings misses the required upcoming features")

    for match in EXPERIMENTAL.finditer(code):
        line = code.count("\n", 0, match.start()) + 1
        if not MARKER.search(raw_lines[line - 1]):
            errors.append(f"Package.swift:{line}: experimental feature without `guard:allow-experimental D<n>`")
    return errors


def xcode_errors(path: Path) -> list[str]:
    try:
        result = subprocess.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
            check=True, capture_output=True, text=True,
        )
        objects = json.loads(result.stdout)["objects"]
        targets = [entry for entry in objects.values() if entry["isa"] == "PBXNativeTarget"]
        if not targets:
            return [f"{PROJECT}: no native targets found"]
        errors = []
        for target in targets:
            configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
            if not configs:
                errors.append(f"{PROJECT}: {target['name']} has no build configurations")
            for config in configs:
                entry = objects[config]
                flags = entry["buildSettings"].get("OTHER_SWIFT_FLAGS", "")
                if isinstance(flags, list):
                    flags = " ".join(flags)
                missing = sorted(set(REQUIRED) - set(PBX_FEATURE.findall(flags)))
                if missing:
                    scope = f"{target['name']}/{entry['name']}"
                    errors.append(f"{PROJECT}: {scope} OTHER_SWIFT_FLAGS misses {', '.join(missing)}")
        return errors
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError, TypeError, AttributeError):
        return [f"{PROJECT}: unable to read native build configurations"]


def check(root: Path) -> list[str]:
    package = root / "Package.swift"
    project = root / PROJECT
    return (package_errors(package) if package.exists() else []) + (
        xcode_errors(project) if project.exists() else []
    )


if __name__ == "__main__":
    sys.exit(run("check_package_features", check))
