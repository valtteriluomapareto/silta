import Darwin
import Foundation

/// Git probes stay outside the SQL write. Recheck local evidence for paths that looked inactive.
struct RegisteredCloneInspection {
  let active: [String]
  private let inactive: [(path: String, stamp: [FileStamp?]?)]

  init(paths: [String], workspace: String, git runner: any GitRunner) async throws {
    var active: [String] = []
    var inactive: [(path: String, stamp: [FileStamp?]?)] = []
    for path in paths {
      let stamp = try Self.stamp(path, workspace: workspace)
      if stamp != nil {
        let git = LocationGit(runner: runner, directory: URL(filePath: path))
        do {
          if try await git.commonDirectory() != nil {
            active.append(path)
            continue
          }
        } catch {
          throw WorkspaceRemovalError.registration(workspace)
        }
      }
      inactive.append((path, stamp))
    }
    self.active = active.sorted()
    self.inactive = inactive
  }

  func requireUnchanged(workspace: String) throws {
    for (path, before) in inactive {
      guard try Self.stamp(path, workspace: workspace) == before else {
        throw WorkspaceRemovalError.changed(workspace)
      }
    }
  }

  private struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let seconds: time_t
    let nanoseconds: Int
  }

  /// The registration and Git discovery markers on its resolved ancestor chain.
  private static func stamp(_ path: String, workspace: String) throws -> [FileStamp?]? {
    guard let entry = try fileStamp(path, workspace: workspace) else { return nil }
    var stamps: [FileStamp?] = [entry]
    var ancestor = URL(filePath: path).resolvingSymlinksInPath()
    while true {
      for marker in [".git", "HEAD", "objects", "refs"] {
        stamps.append(try fileStamp(ancestor.appending(path: marker).path, workspace: workspace))
      }
      if ancestor.path == "/" { break }
      ancestor.deleteLastPathComponent()
    }
    return stamps
  }

  private static func fileStamp(_ path: String, workspace: String) throws -> FileStamp? {
    var entry = stat()
    if stat(path, &entry) == 0 {
      return FileStamp(
        device: entry.st_dev, inode: entry.st_ino,
        seconds: entry.st_ctimespec.tv_sec, nanoseconds: entry.st_ctimespec.tv_nsec)
    }
    if errno == ENOENT || errno == ENOTDIR { return nil }
    throw WorkspaceRemovalError.registration(workspace)
  }
}
