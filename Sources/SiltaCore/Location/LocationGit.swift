import Foundation

struct LocationGit {
  let runner: any GitRunner
  let directory: URL

  func value(_ arguments: [String], optional: Bool = false) async throws -> String? {
    let result: GitResult
    do {
      result = try await runner.run(
        .init(arguments: ["--no-lazy-fetch"] + arguments, directory: directory))
    } catch {
      throw LocationError.git
    }
    guard result.termination == .exit(0) else {
      if optional, case .exit = result.termination { return nil }
      throw LocationError.git
    }
    guard var text = String(data: result.stdout, encoding: .utf8) else { throw LocationError.git }
    if text.hasSuffix("\n") { text.removeLast() }
    return text
  }

  func required(_ arguments: [String]) async throws -> String {
    guard let value = try await value(arguments) else { throw LocationError.git }
    return value
  }

  func commonDirectory() async throws -> URL? {
    let result: GitResult
    do {
      result = try await runner.run(
        .init(
          arguments: [
            "--no-lazy-fetch", "rev-parse", "--path-format=absolute", "--git-common-dir",
          ],
          directory: directory))
    } catch { throw LocationError.git }
    guard result.termination == .exit(0) else {
      if case .exit = result.termination,
        (String(bytes: result.stderr, encoding: .utf8) ?? "").contains("not a git repository"),
        !hasRepositoryMarker
      {
        return nil
      }
      throw LocationError.git
    }
    guard var path = String(data: result.stdout, encoding: .utf8) else { throw LocationError.git }
    if path.hasSuffix("\n") { path.removeLast() }
    return try LocationPath.canonical(URL(filePath: path))
  }

  private var hasRepositoryMarker: Bool {
    var ancestor = directory
    while ancestor.path != "/" {
      if FileManager.default.fileExists(atPath: ancestor.appending(path: ".git").path) {
        return true
      }
      ancestor.deleteLastPathComponent()
    }
    return false
  }

  func refSHA(_ ref: String) async throws -> String? {
    try await value(
      ["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"],
      optional: true)
  }

  func evidence(branch: String?, candidates: [LocationCandidate]) async throws
    -> (app: String?, reason: String)?
  {
    func match(_ ref: String) -> String? {
      let matching = candidates.filter { candidate in
        ([candidate.ref] + [candidate.prodRef].compactMap { $0 })
          .contains { LocationGit.normalized($0) == LocationGit.normalized(ref) }
      }
      return matching.count == 1 ? matching.first?.app : nil
    }
    if let branch {
      if let app = match(branch) { return (app, "exact_ref") }
      if let upstream = try await value(
        ["rev-parse", "--abbrev-ref", "@{upstream}"], optional: true),
        let app = match(upstream)
      {
        return (app, "upstream")
      }
      let reflog = try await value(
        ["reflog", "show", "--format=%H%x09%gs", "refs/heads/" + branch], optional: true)
      if let oldest = reflog?.split(separator: "\n").last {
        let entry = oldest.split(separator: "\t", maxSplits: 1)
        if entry.count == 2, entry[1].hasPrefix("branch: Created from ") {
          let named = String(entry[1].dropFirst("branch: Created from ".count))
          let origin =
            named == "HEAD"
            ? try await implicitOrigin(branch: branch, sha: String(entry[0])) : named
          if let origin {
            if let app = match(origin) { return (app, "reflog") }
            return (nil, "non_app_ref")
          }
        }
      }
    }
    return nil
  }

  private func implicitOrigin(branch: String, sha: String) async throws -> String? {
    let history = try await value(["reflog", "show", "--format=%H%x09%gs", "HEAD"], optional: true)
    let prefix = sha + "\tcheckout: moving from "
    let suffix = " to " + branch
    guard
      let entry = history?.split(separator: "\n").reversed().first(where: {
        $0.hasPrefix(prefix) && $0.hasSuffix(suffix)
      })
    else { return nil }
    return String(entry.dropFirst(prefix.count).dropLast(suffix.count))
  }

  static func normalized(_ ref: String) -> String {
    ref.hasPrefix("origin/") ? String(ref.dropFirst(7)) : ref
  }
}
