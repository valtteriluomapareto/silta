import Darwin
package import Foundation
import Synchronization

/// The synthetic Acme Git suite that `scripts/make-fixtures.sh` builds.
///
/// The script spawns dozens of Git processes. Run once per test, it made fixture setup
/// the busiest part of a loaded parallel suite and outlived its timeout. So each test
/// process builds one template, and every test gets a copy whose absolute paths (remote
/// URLs, worktree links, reflogs) are rewritten from the template to its own.
package enum AcmeFixtures {
  /// `scripts/make-fixtures.sh` in this checkout.
  package static let script = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "scripts/make-fixtures.sh")

  /// Lays the suite out in `destination`, which must be absent or empty, as the script
  /// would. A failed template build returns the script's result to every later caller in
  /// the process, so a broken build fails fast instead of being retried behind the lock.
  package static func make(at destination: URL) throws -> CLIResult {
    let fm = FileManager.default
    if fm.fileExists(atPath: destination.path) {
      guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
        return CLIResult(
          termination: .exit(1), stdout: "", stderr: "fixture destination must be empty\n")
      }
      try fm.removeItem(at: destination)
    }
    let template: URL
    switch try built() {
    case .success(let url): template = url
    case .failure(let failure): return failure.result
    }
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: template, to: destination)
    try relocate(destination, from: realPath(template), to: realPath(destination))
    return CLIResult(termination: .exit(0), stdout: "", stderr: "")
  }

  /// The real path of this process's template, which no copy may still name.
  package static func templatePath() throws -> String? {
    guard case .success(let url) = try built() else { return nil }
    return try realPath(url)
  }

  fileprivate struct Failure: Error {
    let result: CLIResult
  }

  private static func built() throws -> Result<URL, Failure> {
    try template.withLock { cached in
      if let cached { return cached }
      let fm = FileManager.default
      if fm.fileExists(atPath: templateBase.path) { try fm.removeItem(at: templateBase) }
      try fm.createDirectory(at: templateBase, withIntermediateDirectories: true)
      atexit { try? FileManager.default.removeItem(at: templateBase) }  // best-effort temp cleanup
      let fixtures = templateBase.appending(path: "acme", directoryHint: .isDirectory)
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"), [script.path, fixtures.path], in: templateBase)
      let outcome: Result<URL, Failure> =
        result.termination == .exit(0) ? .success(fixtures) : .failure(Failure(result: result))
      cached = outcome
      return outcome
    }
  }

  /// Rewrites every file that names the template's real path. Only Git's text metadata
  /// does; objects are compressed, so they never contain it.
  private static func relocate(_ root: URL, from old: String, to new: String) throws {
    let old = Data(old.utf8)
    let new = Data(new.utf8)
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
    else { return }
    for case let file as URL in files
    where try file.resourceValues(forKeys: Set(keys)).isRegularFile == true {
      let data = try Data(contentsOf: file)
      guard data.firstRange(of: old) != nil else { continue }
      try Data(data.replacing(old, with: new)).write(to: file)
    }
  }

  private static func realPath(_ url: URL) throws -> String {
    // URL.resolvingSymlinksInPath() maps /private/var back to /var; Git records the real path.
    guard let resolved = Darwin.realpath(url.path, nil) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

private let templateBase = FileManager.default.temporaryDirectory
  .appending(path: "silta-fixtures-\(getpid())", directoryHint: .isDirectory)
private let template = Mutex<Result<URL, AcmeFixtures.Failure>?>(nil)
