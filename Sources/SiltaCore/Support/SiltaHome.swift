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
    userHome: URL? = nil,
    temporaryRoots: [URL]? = nil,
    deterministic: Bool = false
  ) throws -> SiltaHome {
    let userHome = userHome ?? FileManager.default.homeDirectoryForCurrentUser
    let temporaryRoots =
      temporaryRoots ?? [FileManager.default.temporaryDirectory, URL(filePath: "/tmp")]
    let override = environment["SILTA_HOME"]
    let defaultHome = userHome.appending(path: ".silta")
    let realHome: URL
    do {
      realHome = try canonicalURL(defaultHome)
    } catch {
      guard override != nil else { throw error }
      // A broken unused default must not prevent an isolated custom home. A dangling
      // symlink names where the real home will be created, so that is the real home.
      let link = defaultHome.path
      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link)  // not a link
      let base = try canonicalURL(userHome)
      let path = target ?? ".silta"
      realHome = path.hasPrefix("/") ? URL(filePath: path) : base.appending(path: path)
    }
    if let override, !override.hasPrefix("/") { throw SeamError.invalidHome }
    let url = override.map { URL(filePath: $0) } ?? realHome
    let canonical = try canonicalURL(url)
    let roots = try temporaryRoots.map { try canonicalURL($0) }
    let isRealHome = identity(canonical) == identity(realHome)
    let isTemporary = roots.contains { root in
      let rootPath = root.path
      return canonical.path.hasPrefix(rootPath + "/")
    }
    return SiltaHome(
      url: canonical, permitsDeterminism: !isRealHome && (deterministic || isTemporary))
  }
}

/// The file identity of the deepest ancestor `stat` can reach, plus the components
/// below it lowercased. Paths can't prove identity: realpath leaves firmlinks such as
/// `/System/Volumes/Data/Users/…` as they are, and volumes may ignore case. A broken
/// default home (a symlink loop, say) counts as missing, so an override still works.
private func identity(_ url: URL) -> [String] {
  var ancestor = url
  var missing: [String] = []
  var info = stat()
  while stat(ancestor.path, &info) != 0, ancestor.path != "/" {
    missing.append(ancestor.lastPathComponent.lowercased())
    ancestor.deleteLastPathComponent()
  }
  return ["\(info.st_dev):\(info.st_ino)"] + missing.reversed()
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
