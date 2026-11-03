import Foundation

/// A source snapshot whose postcommit cleanup cannot turn into a retry of creation.
struct PlanSource: Sendable {
  private struct Location: Equatable, Sendable {
    var root: URL

    var administrative: [URL]
  }

  private struct Snapshot: Equatable, Sendable {
    var canonical: URL

    var device: UInt64

    var inode: UInt64

    var content: Data
  }

  private var source: URL

  private var location: Location

  private var relative: String

  private var snapshot: Snapshot

  static func validate(
    _ source: URL, content: Data, directory: URL, runner: any GitRunner
  ) async throws -> PlanSource {
    let location = try await locate(directory: directory, runner: runner)
    let captured = try capture(source, location: location)
    guard captured.content == content else {
      throw TaskError.invalid("The source changed while being read; inspect it before importing.")
    }
    let relative = String(captured.canonical.path.dropFirst(location.root.path.count + 1))
    let checked = PlanSource(
      source: source, location: location, relative: relative, snapshot: captured)
    guard try await checked.isUntracked(runner: runner) else {
      throw TaskError.invalid("--delete refuses a tracked source; import without --delete.")
    }
    guard try capture(source, location: location) == captured else {
      throw TaskError.invalid("The source changed during validation; inspect it before importing.")
    }
    return checked
  }

  func removeIfUnchanged(runner: any GitRunner) async -> Bool {
    do {
      guard try await isUntracked(runner: runner),
        try await Self.locate(directory: location.root, runner: runner) == location,
        try Self.capture(source, location: location) == snapshot
      else { return false }
      try FileManager.default.removeItem(at: source)
      return true
    } catch {
      return false
    }
  }

  private static func locate(directory: URL, runner: any GitRunner) async throws -> Location {
    let result = try await run(
      ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
      directory: directory, runner: runner)
    if result.termination == .exit(128) {
      throw TaskError.invalid("--delete requires a file inside the current Git worktree.")
    }
    guard result.termination == .exit(0),
      let raw = String(data: result.stdout, encoding: .utf8)
    else { throw TaskError.git }
    let paths = raw.split(separator: "\n").map {
      URL(filePath: String($0), directoryHint: .isDirectory).resolvingSymlinksInPath()
    }
    guard paths.count == 3 else { throw TaskError.git }
    return Location(root: paths[0], administrative: Array(paths.dropFirst()))
  }

  private func isUntracked(runner: any GitRunner) async throws -> Bool {
    let result = try await Self.run(
      ["--literal-pathspecs", "ls-files", "--error-unmatch", "--", relative],
      directory: location.root, runner: runner)
    switch result.termination {
    case .exit(0): return false
    case .exit(1): return true
    default: throw TaskError.git
    }
  }

  private static func capture(_ source: URL, location: Location) throws -> Snapshot {
    do {
      let canonical = source.resolvingSymlinksInPath()
      let protected: Set<String> = [".git", ".claude", ".codex", ".opencode", ".agents", ".cursor"]
      guard canonical.path.hasPrefix(location.root.path + "/"),
        protected.isDisjoint(with: canonical.pathComponents),
        protected.isDisjoint(with: source.standardizedFileURL.pathComponents),
        !location.administrative.contains(where: { canonical.path.hasPrefix($0.path + "/") })
      else {
        throw TaskError.invalid(
          "--delete refuses sources outside the worktree or in Git/harness directories.")
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let device = attributes[.systemNumber] as? NSNumber,
        let inode = attributes[.systemFileNumber] as? NSNumber
      else {
        throw TaskError.invalid("--delete requires a regular file, not a symlink or directory.")
      }
      return Snapshot(
        canonical: canonical, device: device.uint64Value, inode: inode.uint64Value,
        content: try Data(contentsOf: source))
    } catch let error as TaskError {
      throw error
    } catch {
      throw TaskError.input
    }
  }

  private static func run(_ args: [String], directory: URL, runner: any GitRunner) async throws
    -> GitResult
  {
    do { return try await runner.run(.init(arguments: args, directory: directory)) } catch {
      throw TaskError.git
    }
  }
}
