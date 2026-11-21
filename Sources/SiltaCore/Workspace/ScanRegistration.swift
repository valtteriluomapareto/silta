import Foundation
import GRDB

/// A configured repo and its optional machine-local path.
struct ScanRegistration {
  let id: Int64
  let repo: String
  let workspace: String
  let path: String?
  private let evidence: Evidence

  var isIdentity: Bool { evidence == .identity }
  var isWeakSlug: Bool { evidence == .slugOnly }
  var permitsSelectedSlug: Bool {
    evidence == .relativeOrigin || evidence == .slugOnly || evidence == .scopedAlias
  }

  private enum Evidence {
    case identity
    case relativeOrigin
    case slugOnly
    case scopedAlias
    case possibleAlias
  }

  private init(_ row: Row, evidence: Evidence) {
    id = row["id"]
    repo = row["repo"]
    workspace = row["workspace"]
    path = row["path"]
    self.evidence = evidence
  }

  private static let registrations = """
    SELECT repo.id, repo.slug AS repo, workspace.slug AS workspace, repo_path.path, repo.remote_url
    FROM repo JOIN workspace ON workspace.id=repo.workspace_id
    LEFT JOIN repo_path ON repo_path.repo_id=repo.id
    """

  /// Canonical path ownership wins. Otherwise keep all plausible declarations
  /// visible, including pathless repositories configured without a remote.
  static func matching(path: String, slug: String, origin: String?, in db: Database) throws
    -> [Self]
  {
    let bound = try Row.fetchAll(
      db,
      sql: registrations + " WHERE repo_path.path=? ORDER BY workspace.slug, repo.slug",
      arguments: [path])
    if !bound.isEmpty { return bound.map { Self($0, evidence: .identity) } }
    let stableOrigin = origin.map(identifiableOrigin) ?? false
    let network = origin.map(networkOrigin) ?? false
    let normalizedOrigin = origin.flatMap(hostedOrigin)
    return try Row.fetchAll(
      db,
      sql: registrations + """

        WHERE (repo_path.path IS NULL AND repo.slug=?) OR (? IS NOT NULL AND repo.remote_url<>'')
        ORDER BY workspace.slug, repo.slug
        """,
      arguments: [slug, origin]
    ).compactMap { row -> Self? in
      let binding: String? = row["path"]
      let remote: String? = row["remote_url"]
      let repo: String = row["repo"]
      let exactOrigin = remote != nil && remote != "" && remote == origin
      let alias = normalizedOrigin != nil && remote.flatMap(hostedOrigin) == normalizedOrigin
      let pathless = binding == nil && repo == slug && (remote == nil || remote == "")
      let evidence: Evidence
      if (exactOrigin && stableOrigin) || (alias && normalizedOrigin?.hasStandardHosting == true) {
        evidence = .identity
      } else if pathless {
        evidence = network ? .slugOnly : .identity
      } else if exactOrigin {
        evidence = .relativeOrigin
      } else if alias {
        let https = origin?.lowercased().hasPrefix("https://") == true
        let remoteHTTPS = remote?.lowercased().hasPrefix("https://") == true
        evidence = https != remoteHTTPS ? .scopedAlias : .possibleAlias
      } else {
        return nil
      }
      return Self(row, evidence: evidence)
    }
  }

  private struct HostedOrigin: Equatable {
    let host: String
    let path: String

    var hasStandardHosting: Bool {
      ["github.com", "gitlab.com", "bitbucket.org", "dev.azure.com"].contains(host)
    }
  }

  /// A possible hosting alias. Generic SSH paths can be absolute or relative.
  private static func hostedOrigin(_ origin: String) -> HostedOrigin? {
    let host: String
    let path: Substring
    let scpUser: Substring?
    if let scp = origin.wholeMatch(of: #/([a-zA-Z0-9_.-]+)@([a-zA-Z0-9.-]+):(.+)/#) {
      host = scp.2.lowercased()
      guard host == "vs-ssh.visualstudio.com" || scp.1 == "git" else { return nil }
      scpUser = scp.1
      path = scp.3
    } else {
      guard let url = URLComponents(string: origin),
        let hostname = url.host, hostname.wholeMatch(of: /[a-zA-Z0-9.-]+/) != nil,
        url.query == nil, url.fragment == nil, url.password == nil
      else { return nil }
      switch url.scheme?.lowercased() {
      case "https":
        guard url.user == nil, url.port == nil || url.port == 443 else { return nil }
      case "ssh":
        guard url.user == "git", url.port == nil || url.port == 22 else { return nil }
      default: return nil
      }
      host = hostname.lowercased()
      scpUser = nil
      path = url.percentEncodedPath.dropFirst()
    }
    let trimmed = path.hasSuffix("/") ? path.dropLast() : path
    guard trimmed.wholeMatch(of: /[a-zA-Z0-9_.-]+(\/[a-zA-Z0-9_.-]+)+/) != nil,
      !trimmed.split(separator: "/").contains(where: { $0 == "." || $0 == ".." || $0 == ".git" })
    else { return nil }

    if ["dev.azure.com", "ssh.dev.azure.com", "vs-ssh.visualstudio.com"].contains(host) {
      return azureOrigin(
        host, path: trimmed, scpUser: scpUser, https: origin.lowercased().hasPrefix("https://"))
    }
    let caseIndependent = host == "github.com" || host == "gitlab.com"
    let name = caseIndependent ? trimmed.lowercased() : String(trimmed)
    return HostedOrigin(host: host, path: name.hasSuffix(".git") ? String(name.dropLast(4)) : name)
  }

  private static func azureOrigin(
    _ host: String, path: Substring, scpUser: Substring?, https: Bool
  ) -> HostedOrigin? {
    let parts = path.lowercased().split(separator: "/")
    guard parts.count == 4 else { return nil }
    if host == "dev.azure.com", https, parts[2] == "_git" {
      return HostedOrigin(
        host: "dev.azure.com", path: [parts[0], parts[1], parts[3]].joined(separator: "/"))
    }
    guard !https, parts[0] == "v3", host != "dev.azure.com" else { return nil }
    if host == "vs-ssh.visualstudio.com", scpUser?.lowercased() != String(parts[1]) { return nil }
    return HostedOrigin(host: "dev.azure.com", path: parts.dropFirst().joined(separator: "/"))
  }

  private static func networkOrigin(_ origin: String) -> Bool {
    !origin.hasPrefix("/") && !origin.lowercased().hasPrefix("file:") && identifiableOrigin(origin)
  }

  /// Git treats paths without a scheme or an scp-style host as local paths.
  private static func identifiableOrigin(_ origin: String) -> Bool {
    if origin.hasPrefix("/") { return true }
    guard let colon = origin.firstIndex(of: ":") else { return false }
    return colon != origin.startIndex && !origin[..<colon].contains("/")
  }

  static func identities(_ matches: [[Self]]) -> [Self]? {
    let rows = matches.compactMap { $0.count == 1 && $0.first?.isIdentity == true ? $0.first : nil }
    guard rows.count == matches.count, Set(rows.map(\.id)).count == rows.count else { return nil }
    return rows
  }

  static func recovery(_ matches: [[Self]], paths: [String], roots: [String]) -> ScanError? {
    let choices = Set(matches.flatMap { $0.map(\.workspace) }).sorted()
    guard !choices.isEmpty else { return nil }
    let usable =
      choices.count == 1
      && identities(matches).map { rows in
        zip(rows, paths).allSatisfy { row, path in row.path == nil || row.path == path }
      } == true
    return .registeredWorkspaces(choices, roots: usable ? roots : nil)
  }
}
