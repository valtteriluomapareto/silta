import Darwin
import Foundation

extension ExportService {
  /// Keeps the configured home's canonical spelling for the no-follow walk.
  /// Foundation can shorten an existing /private/tmp path to the /tmp alias.
  static func normalizedRoot(_ root: URL, home: URL) -> URL {
    isDefaultRoot(root, home: home)
      ? DirectoryPath.canonicalHome(home).appending(path: "exports", directoryHint: .isDirectory)
      : root.standardizedFileURL
  }

  /// An absent default root is safe to create later. A present root must open without links.
  static func validateDefaultRoot(_ root: URL, home: URL) throws {
    guard isDefaultRoot(root, home: home) else { return }
    do {
      let directory = try DirectoryPath.open(
        DirectoryPath.canonicalHome(home).appending(path: "exports"))
      close(directory)
    } catch let error as POSIXError where error.code == .ENOENT {
      return
    } catch {
      throw ExportError.defaultRootUnavailable
    }
  }

  private static func isDefaultRoot(_ root: URL, home: URL) -> Bool {
    root.standardizedFileURL.path == home.appending(path: "exports").standardizedFileURL.path
  }

  static func openRoot(_ root: URL, home: URL, workspace: String) throws -> Int32 {
    if isDefaultRoot(root, home: home) {
      do {
        return try DirectoryPath.open(root, creating: true)
      } catch {
        throw ExportError.defaultRootUnavailable
      }
    }
    let failed = ExportError.unwritable(path: root.path, workspace: workspace)
    do {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw failed
    }
    let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else {
      let crashed = leftovers(in: root, prefix: ".\(workspace).export-")
      if !crashed.isEmpty { throw ExportFailure(error: failed, leftovers: crashed) }
      throw failed
    }
    return directory
  }

  /// Work directories an earlier export left under `root`; a root that can't be listed
  /// is reported itself, since it may hold some.
  static func leftovers(in root: URL, prefix: String) -> [ExportLeftover] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)  // reported
    else {
      return [ExportLeftover(path: root.path, reason: "could not be listed for work directories")]
    }
    return names.filter { $0.hasPrefix(prefix) }.sorted().map {
      ExportLeftover(
        path: root.appending(path: $0).path, reason: "was left by an export that did not finish")
    }
  }
}
