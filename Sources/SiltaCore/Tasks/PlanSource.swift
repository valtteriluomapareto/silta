import Foundation

/// A source snapshot whose postcommit cleanup cannot turn into a retry of creation.
struct PlanSource: Sendable {
  private struct Snapshot: Equatable, Sendable {
    var canonical: URL

    var device: UInt64

    var inode: UInt64

    var content: Data
  }

  private var source: URL

  private var root: URL

  private var relative: String

  private var snapshot: Snapshot

  static func validate(
    _ source: URL, content: Data, directory: URL, runner: any GitRunner
  ) async throws -> PlanSource {
    let rootResult = try await run(
      ["rev-parse", "--show-toplevel"], directory: directory, runner: runner)
    if rootResult.termination == .exit(128) {
      throw TaskError.invalid("--delete requires a file inside the current Git worktree.")
    }
    guard rootResult.termination == .exit(0),
      let raw = String(data: rootResult.stdout, encoding: .utf8),
      !raw.trimmingCharacters(in: .newlines).isEmpty
    else { throw TaskError.git }
    let root = URL(
      filePath: raw.trimmingCharacters(in: .newlines), directoryHint: .isDirectory
    ).resolvingSymlinksInPath()
    let captured = try capture(source, root: root)
    guard captured.content == content else {
      throw TaskError.invalid("The source changed while being read; inspect it before importing.")
    }
    let relative = String(captured.canonical.path.dropFirst(root.path.count + 1))
    let checked = PlanSource(source: source, root: root, relative: relative, snapshot: captured)
    guard try await checked.isUntracked(runner: runner) else {
      throw TaskError.invalid("--delete refuses a tracked source; import without --delete.")
    }
    guard try capture(source, root: root) == captured else {
      throw TaskError.invalid("The source changed during validation; inspect it before importing.")
    }
    return checked
  }

  func removeIfUnchanged(runner: any GitRunner) async -> Bool {
    do {
      guard try await isUntracked(runner: runner),
        try Self.capture(source, root: root) == snapshot
      else { return false }
      try FileManager.default.removeItem(at: source)
      return true
    } catch {
      return false
    }
  }

  private func isUntracked(runner: any GitRunner) async throws -> Bool {
    let result = try await Self.run(
      ["ls-files", "--error-unmatch", "--", relative], directory: root, runner: runner)
    switch result.termination {
    case .exit(0): return false
    case .exit(1): return true
    default: throw TaskError.git
    }
  }

  private static func capture(_ source: URL, root: URL) throws -> Snapshot {
    do {
      let canonical = source.resolvingSymlinksInPath()
      let harnesses: Set<String> = [".claude", ".codex", ".opencode", ".agents", ".cursor"]
      guard canonical.path.hasPrefix(root.path + "/"),
        harnesses.isDisjoint(with: canonical.pathComponents),
        harnesses.isDisjoint(with: source.standardizedFileURL.pathComponents)
      else {
        throw TaskError.invalid(
          "--delete refuses sources outside the worktree or in harness directories.")
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
