import Darwin
package import Foundation

/// Runs `body` with a fresh, empty temporary directory and removes it afterwards, also
/// when `body` throws.
///
/// The URL is the real path (`/private/var/…` rather than `/var/…` on macOS), so it
/// compares equal to the working directory a child process reports.
package func withScratchDirectory<T>(_ body: (URL) throws -> T) throws -> T {
  let base = FileManager.default.temporaryDirectory
    .appending(path: "silta-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: base) }  // best-effort cleanup of a temp dir
  // URL.resolvingSymlinksInPath() maps /private/var back to /var, so ask the system.
  guard let resolved = realpath(base.path, nil) else {
    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: base.path])
  }
  defer { free(resolved) }
  return try body(URL(filePath: String(cString: resolved), directoryHint: .isDirectory))
}
