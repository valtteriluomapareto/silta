"""Keep the app and root package on identical shared dependencies."""
import json
from pathlib import Path
from swift_source import run

APP_PINS = Path("App/SiltaApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")


def pins(path):
    value = json.loads(path.read_text())
    if value.get("version") not in (2, 3) or not isinstance(value.get("pins"), list):
        raise ValueError("unsupported Package.resolved")
    result = {}
    for pin in value["pins"]:
        identity, state = pin["identity"], pin["state"]
        if not isinstance(identity, str) or identity in result:
            raise ValueError("invalid or duplicate package identity")
        result[identity] = (state["version"], state["revision"])
    return result


def check(root: Path) -> list[str]:
    try:
        expected = pins(root / "Package.resolved")
        actual = pins(root / APP_PINS)
        errors = [f"{APP_PINS}:1: missing shared package {identity}" for identity in expected.keys() - actual.keys()]
        errors += [f"{APP_PINS}:1: {identity} must match the root version and revision"
                   for identity in expected.keys() & actual.keys() if expected[identity] != actual[identity]]
        return sorted(errors)
    except (OSError, ValueError, KeyError, TypeError) as error:
        return [f"{APP_PINS}:1: cannot validate package pins ({type(error).__name__})"]


if __name__ == "__main__":
    raise SystemExit(run("check_app_pins", check))
