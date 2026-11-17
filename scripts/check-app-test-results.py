"""Require nonempty successful app acceptance from xcresult JSON reports.

Usage: python3 scripts/check-app-test-results.py summary.json tests.json SuiteName [...]
"""
import json
import sys


def check(summary, tests, required):
    if not isinstance(summary, dict) or not isinstance(tests, dict):
        return ["unsupported xcresult report"]
    fields = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    if any(type(summary.get(key)) is not int for key in fields):
        return ["missing or malformed test counts"]
    errors = []
    if (summary.get("result") != "Passed" or summary["totalTestCount"] <= 0
            or summary["passedTests"] != summary["totalTestCount"]
            or any(summary[key] != 0 for key in fields[2:])):
        errors.append("app tests must all pass with no skips or expected failures")
    nodes = tests.get("testNodes")
    if not isinstance(nodes, list) or not nodes:
        return errors + ["missing test tree"]

    def flatten(values):
        for node in values:
            if not isinstance(node, dict) or not isinstance(node.get("children", []), list):
                raise ValueError("malformed test tree")
            yield node
            yield from flatten(node.get("children", []))

    try:
        all_nodes = list(flatten(nodes))
        for name in required:
            suites = [node for node in all_nodes if node.get("nodeType") == "Test Suite" and node.get("name") == name]
            if not any(any(child.get("nodeType") == "Test Case" and child.get("result") == "Passed"
                           for child in flatten(suite.get("children", []))) for suite in suites):
                errors.append(f"required suite {name} did not run and pass")
    except ValueError:
        errors.append("malformed test tree")
    return errors


def main(arguments):
    if len(arguments) < 3:
        print(__doc__, file=sys.stderr)
        return 64
    try:
        with open(arguments[0]) as source:
            summary = json.load(source)
        with open(arguments[1]) as source:
            tests = json.load(source)
        errors = check(summary, tests, arguments[2:])
    except (OSError, ValueError) as error:
        errors = [f"cannot read xcresult reports: {type(error).__name__}"]
    for error in errors:
        print("app verification: " + error, file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
