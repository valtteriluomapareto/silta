import Darwin
package import Foundation

/// Canonical data-directory configuration. Resolution never creates or writes files.
package struct SiltaHome: Sendable {
  package let url: URL
  package let permitsDeterminism: Bool

  /// Resolves an absolute SILTA_HOME, defaulting to the user's `.silta` directory.
  /// Overrides are safe only below an OS temporary root, or in explicit deterministic mode.
  /// The default home and aliases to it are never automatically considered temporary.
  package static func resolve(
    environment: [String: String],
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    temporaryRoots: [URL] = [FileManager.default.temporaryDirectory, URL(filePath: "/tmp")],
    deterministic: Bool = false
  ) throws -> SiltaHome {
    let realHome = try canonicalURL(userHome.appending(path: ".silta"))
    let override = environment["SILTA_HOME"]
    if let override, !override.hasPrefix("/") { throw HomeError.invalidPath }
    let url = override.map { URL(filePath: $0) } ?? realHome
    let canonical = try canonicalURL(url)
    let roots = try temporaryRoots.map { try canonicalURL($0) }
    let isTemporary =
      override != nil && canonical != realHome
      && roots.contains { root in
        let rootPath = root.path
        return canonical.path.hasPrefix(rootPath + "/")
      }
    return SiltaHome(url: canonical, permitsDeterminism: deterministic || isTemporary)
  }
}

// Resolve the existing ancestor before appending missing components: Foundation's
// symlink normalization treats nonexistent /private/var descendants inconsistently.
private func canonicalURL(_ url: URL) throws -> URL {
  guard !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
    throw HomeError.invalidPath
  }
  var ancestor = url
  var missing: [String] = []
  while true {
    var info = stat()
    if lstat(ancestor.path, &info) == 0 {
      guard let resolved = realpath(ancestor.path, nil) else { throw HomeError.invalidPath }
      defer { free(resolved) }
      return missing.reversed().reduce(URL(filePath: String(cString: resolved))) {
        $0.appending(path: $1)
      }
    }
    guard errno == ENOENT, ancestor.path != "/" else { throw HomeError.invalidPath }
    missing.append(ancestor.lastPathComponent)
    let parent = ancestor.deletingLastPathComponent()
    guard parent.path != ancestor.path else { throw HomeError.invalidPath }
    ancestor = parent
  }
}

private enum HomeError: Error { case invalidPath }
