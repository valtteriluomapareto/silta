import Darwin
package import Foundation

/// Canonical data-directory configuration. Resolution never creates or writes files.
package struct SiltaHome: Sendable {
  /// Canonical absolute path; resolving configuration never creates it.
  package let url: URL
  /// Whether deterministic overrides may be used at this home.
  package let permitsDeterminism: Bool

  /// Resolves an absolute SILTA_HOME, defaulting to the user's `.silta` directory.
  /// Overrides require a path below an OS temporary root, or explicit deterministic mode.
  /// The default home and aliases to it always disable overrides, including explicit mode.
  /// Temporary roots are the OS user temp directory and `/tmp`. Dot components and
  /// dangling symlinks are rejected; invalid paths throw `SeamError.invalidHome`.
  package static func resolve(
    environment: [String: String],
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    temporaryRoots: [URL] = [FileManager.default.temporaryDirectory, URL(filePath: "/tmp")],
    deterministic: Bool = false
  ) throws -> SiltaHome {
    let realHome = try canonicalURL(userHome.appending(path: ".silta"))
    let override = environment["SILTA_HOME"]
    if let override, !override.hasPrefix("/") { throw SeamError.invalidHome }
    let url = override.map { URL(filePath: $0) } ?? realHome
    let canonical = try canonicalURL(url)
    let roots = try temporaryRoots.map { try canonicalURL($0) }
    let isTemporary =
      override != nil && canonical != realHome
      && roots.contains { root in
        let rootPath = root.path
        return canonical.path.hasPrefix(rootPath + "/")
      }
    return SiltaHome(
      url: canonical, permitsDeterminism: canonical != realHome && (deterministic || isTemporary))
  }
}

// Resolve the existing ancestor before appending missing components: Foundation's
// symlink normalization treats nonexistent /private/var descendants inconsistently.
private func canonicalURL(_ url: URL) throws -> URL {
  guard !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
    throw SeamError.invalidHome
  }
  var ancestor = url
  var missing: [String] = []
  while true {
    var info = stat()
    if lstat(ancestor.path, &info) == 0 {
      guard let resolved = realpath(ancestor.path, nil) else { throw SeamError.invalidHome }
      defer { free(resolved) }
      var resolvedInfo = stat()
      guard stat(resolved, &resolvedInfo) == 0, (resolvedInfo.st_mode & S_IFMT) == S_IFDIR else {
        throw SeamError.invalidHome
      }
      return missing.reversed().reduce(URL(filePath: String(cString: resolved))) {
        $0.appending(path: $1)
      }
    }
    guard errno == ENOENT, ancestor.path != "/" else { throw SeamError.invalidHome }
    missing.append(ancestor.lastPathComponent)
    let parent = ancestor.deletingLastPathComponent()
    guard parent.path != ancestor.path else { throw SeamError.invalidHome }
    ancestor = parent
  }
}
