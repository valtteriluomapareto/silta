import Darwin
import Foundation

/// Git probes stay outside the SQL write. Recheck local evidence for paths that looked inactive.
struct RegisteredCloneInspection {
  let active: [String]
  let unresolved: [String]
  private let inactive: [(path: String, stamp: RegistrationStamp?)]

  init(paths: [String], workspace: String, git runner: any GitRunner) async throws {
    var active: [String] = []
    var unresolved: [String] = []
    var inactive: [(path: String, stamp: RegistrationStamp?)] = []
    for path in paths {
      do {
        let stamp = try Self.stamp(path, workspace: workspace)
        guard let stamp else {
          inactive.append((path, nil))
          continue
        }
        let git = LocationGit(runner: runner, directory: URL(filePath: path))
        if try await git.commonDirectory() != nil {
          active.append(path)
        } else if stamp.hasMarker {
          unresolved.append(path)
        } else {
          inactive.append((path, stamp))
        }
      } catch {
        try Task.checkCancellation()
        unresolved.append(path)
      }
    }
    self.active = active.sorted()
    self.unresolved = unresolved.sorted()
    self.inactive = inactive
  }

  func requireUnchanged(workspace: String) throws {
    for (path, before) in inactive {
      guard try Self.stamp(path, workspace: workspace) == before else {
        throw WorkspaceRemovalError.changed(workspace)
      }
    }
  }

  private struct RegistrationStamp: Equatable {
    let files: [FileStamp?]
    let hasMarker: Bool
  }

  private struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let seconds: time_t
    let nanoseconds: Int
  }

  /// The registration and Git discovery markers on its resolved ancestor chain.
  private static func stamp(_ path: String, workspace: String) throws -> RegistrationStamp? {
    guard let entry = try fileStamp(path, workspace: workspace, followLink: true) else {
      return nil
    }
    var stamps: [FileStamp?] = [entry]
    var hasMarker = false
    var ancestor = URL(filePath: path).resolvingSymlinksInPath()
    while true {
      let markers = try [".git", "HEAD", "objects", "refs"].map {
        try fileStamp(ancestor.appending(path: $0).path, workspace: workspace, followLink: false)
      }
      hasMarker =
        hasMarker || markers.first.flatMap({ $0 }) != nil
        || markers.dropFirst().allSatisfy { $0 != nil }
      stamps += markers
      if ancestor.path == "/" { break }
      ancestor.deleteLastPathComponent()
    }
    return RegistrationStamp(files: stamps, hasMarker: hasMarker)
  }

  private static func fileStamp(_ path: String, workspace: String, followLink: Bool) throws
    -> FileStamp?
  {
    var entry = stat()
    if (followLink ? stat(path, &entry) : lstat(path, &entry)) == 0 {
      return FileStamp(
        device: entry.st_dev, inode: entry.st_ino,
        seconds: entry.st_ctimespec.tv_sec, nanoseconds: entry.st_ctimespec.tv_nsec)
    }
    if errno == ENOENT || errno == ENOTDIR { return nil }
    throw WorkspaceRemovalError.changed(workspace)
  }
}
