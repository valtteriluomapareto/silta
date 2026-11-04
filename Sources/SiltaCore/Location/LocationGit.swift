import Foundation

struct LocationGit {
  let runner: any GitRunner
  let directory: URL

  func value(_ arguments: [String], optional: Bool = false) async throws -> String? {
    let result: GitResult
    do {
      result = try await runner.run(
        .init(arguments: arguments, directory: directory, lazyFetch: false))
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
            "rev-parse", "--path-format=absolute", "--git-common-dir",
          ],
          directory: directory, lazyFetch: false))
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
        ["reflog", "show", "--format=%gs", "refs/heads/" + branch], optional: true)
      if let creation = reflog?.split(separator: "\n").last,
        creation.hasPrefix("branch: Created from ")
      {
        let origin = String(creation.dropFirst("branch: Created from ".count))
        if origin == "HEAD" { return nil }
        if let app = match(origin) { return (app, "reflog") }
        return (nil, "non_app_ref")
      }
    }
    return nil
  }

  static func normalized(_ ref: String) -> String {
    ref.hasPrefix("origin/") ? String(ref.dropFirst(7)) : ref
  }
}
