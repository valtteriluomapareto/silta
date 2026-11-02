package import Foundation
package import Testing

/// Compares output with a checked-in golden file, byte for byte (coding guidelines §6).
///
/// Goldens are written from the spec, not from the code. With `update`, a mismatching
/// or missing golden is rewritten and the check still records an issue, so an update
/// run is never mistaken for a passing run.
package struct Golden: Sendable {
  /// The folder holding the golden files.
  package let directory: URL
  /// Rewrite goldens instead of only comparing.
  package let update: Bool

  /// Goldens in `directory`.
  package init(directory: URL, update: Bool) {
    self.directory = directory
    self.update = update
  }

  /// The calling test target's `Tests/<target>/Golden` folder, updated only with
  /// `SILTA_UPDATE_GOLDENS=1` (which `scripts/verify.sh` refuses in CI).
  package static func forTests(filePath: String = #filePath) -> Golden {
    var target = URL(filePath: filePath).deletingLastPathComponent()
    while target.pathComponents.count > 1,
      target.deletingLastPathComponent().lastPathComponent != "Tests"
    {
      target = target.deletingLastPathComponent()
    }
    return Golden(
      directory: target.appending(path: "Golden", directoryHint: .isDirectory),
      update: ProcessInfo.processInfo.environment["SILTA_UPDATE_GOLDENS"] == "1")
  }

  /// Records an issue unless `actual` is byte-identical to the golden file `name`.
  package func check(
    _ actual: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    let actualBytes = Data(actual.utf8)
    let expectedBytes = FileManager.default.contents(atPath: url.path)
    if expectedBytes == actualBytes {
      return
    }
    if update {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try actualBytes.write(to: url)
        Issue.record(
          "Updated golden \(name); review the diff, then rerun without SILTA_UPDATE_GOLDENS",
          sourceLocation: sourceLocation)
      } catch {
        Issue.record("Couldn't write golden \(name): \(error)", sourceLocation: sourceLocation)
      }
      return
    }
    guard let expectedBytes else {
      Issue.record(
        "Missing golden \(name): write it from the spec at \(url.path)",
        sourceLocation: sourceLocation)
      return
    }
    Issue.record(
      "Golden \(name) differs: \(firstDifference(expectedBytes, actualBytes))",
      sourceLocation: sourceLocation)
  }

  private func firstDifference(_ expected: Data, _ actual: Data) -> String {
    let expectedLines = expected.split(
      separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    let actualLines = actual.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    for index in 0..<max(expectedLines.count, actualLines.count) {
      let want = index < expectedLines.count ? Data(expectedLines[index]) : nil
      let got = index < actualLines.count ? Data(actualLines[index]) : nil
      if want != got {
        return "line \(index + 1)\n  expected: \(shown(want))\n  actual:   \(shown(got))"
      }
    }
    return "same bytes"
  }

  private func shown(_ line: Data?) -> String {
    guard let line else { return "<end of file>" }
    return String(bytes: line, encoding: .utf8) ?? "<\(line.count) bytes, not UTF-8>"
  }
}
