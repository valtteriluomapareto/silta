package import Foundation

/// Runs `body` with a fresh, empty temporary directory and removes it afterwards, also
/// when `body` throws.
///
/// The URL has symlinks resolved (`/var` → `/private/var` on macOS), so it compares
/// equal to the paths a child process reports for its working directory.
package func withScratchDirectory<T>(_ body: (URL) throws -> T) throws -> T {
  let base = FileManager.default.temporaryDirectory
    .appending(path: "silta-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
  let url = base.resolvingSymlinksInPath()
  defer { try? FileManager.default.removeItem(at: url) }  // best-effort cleanup of a temp dir
  return try body(url)
}
