import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct ScanIdentityCommandTests {
  private static let inspect = "silta --ws 'acme' ws show"
  private static let acmeOrigin = "https://github.com/acme-fixture/web.git"
  private static let otherOrigin = "https://github.com/beta-fixture/web.git"

  @Test func networkSlugOnlyOffersInspectionAndAllowsExplicitCreation() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try Self.declare("web", in: store)
      let repo = try Self.clone("beta/web", origin: Self.otherOrigin, in: scratch)
      let before = try Self.identity(store)
      try Self.checkWeakClientHints(repo, in: scratch)
      #expect(try Self.identity(store) == before)
      let created = try Self.run(
        ["init", "--scan", ".", "--slug", "beta", "--prefix", "BE"], repo, scratch)
      let after = try Self.identity(store)
      withKnownIssue("SI-238: A weak slug currently blocks explicit workspace creation.") {
        #expect(created.termination == .exit(0), "\(created.stdout)")
        #expect(after.count == 2)
      }
      #expect(after.first == before.first)
    }
  }

  private static func checkWeakClientHints(_ repo: URL, in scratch: URL) throws {
    for args in [["where"], ["init", "--scan", "."]] {
      let result = try run(args, repo, scratch)
      let error = try TaskStateCommandTests.error(result)
      let next = try #require(error["next"] as? [String])
      withKnownIssue("SI-238: A weak slug currently offers a scoped write.") {
        #expect(next == [inspect])
        #expect((error["message"] as? String ?? "").localizedCaseInsensitiveContains("possible"))
      }
    }
    let brief = try run(["brief"], repo, scratch)
    withKnownIssue("SI-238: Brief currently offers a weak write.") {
      #expect(brief.stdout.contains(inspect))
    }
    #expect(
      try FirstWorkspaceCommandTests.replay(inspect, in: scratch, cwd: repo).termination == .exit(0)
    )
  }

  @Test func namedMixedScanCannotBypassVerifiedOwnership() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try Self.declare("web", in: store)
      try Self.declare("api", origin: "https://github.com/acme-fixture/api.git", in: store)
      let held = try Self.clone(
        "bundle/api", origin: "https://github.com/acme-fixture/api.git", in: scratch)
      try Self.bind(held, in: scratch)
      _ = try Self.clone("bundle/web", origin: Self.otherOrigin, in: scratch)
      let before = try Self.identity(store)
      let scan = try Self.run(
        ["init", "--scan", "bundle", "--slug", "beta", "--prefix", "BE"], scratch, scratch)
      #expect(scan.termination == .exit(6))
      let next = try #require(try TaskStateCommandTests.error(scan)["next"] as? [String])
      withKnownIssue("SI-238: A weak row currently makes the mixed named repair writable.") {
        #expect(next == [Self.inspect])
      }
      #expect(try Self.identity(store) == before)
    }
  }

  @Test(arguments: [
    [
      "https://dev.azure.com/Acme/Delivery/_git/Web",
      "acme@vs-ssh.visualstudio.com:v3/acme/delivery/web",
    ],
    [
      "https://dev.azure.com/Acme/Delivery/_git/Web/",
      "git@ssh.dev.azure.com:v3/acme/delivery/web",
    ],
    ["https://github.com/Acme/Web.git", "git@github.com:acme/web"],
    ["https://gitlab.com/Acme/Web.git", "https://gitlab.com/acme/web/"],
  ])
  func hostedAliasesIdentifyTheOriginalRepo(origins: [String]) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try Self.declare("declared", origin: origins[0], in: store)
      let repo = try Self.clone("newcheckout", origin: origins[1], in: scratch)
      let before = try Self.identity(store)
      let whereResult = try Self.run(["where"], repo, scratch)
      let next = try #require(
        try TaskStateCommandTests.error(whereResult)["next"] as? [String])
      withKnownIssue("SI-238: This hosted spelling currently looks unrelated.") {
        #expect(next.first?.hasPrefix("silta --ws 'acme' init --scan ") == true)
      }
      #expect(try Self.identity(store) == before)
    }
  }

  @Test func discoveryOfASecondCheckoutUsesOnlyInspection() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try Self.declare("web", origin: Self.acmeOrigin, in: store)
      let held = try Self.clone("first/web", origin: Self.acmeOrigin, in: scratch)
      try Self.bind(held, in: scratch)
      let other = try Self.clone("second/web", origin: Self.acmeOrigin, in: scratch)
      let before = try Self.identity(store)
      let found = try Self.run(["where"], other, scratch)
      let brief = try Self.run(["brief"], other, scratch)
      let scan = try Self.run(["init", "--scan", "."], other, scratch)
      #expect(scan.termination == .exit(6))
      #expect(try TaskStateCommandTests.error(scan)["next"] as? [String] == [Self.inspect])
      let foundNext = try TaskStateCommandTests.error(found)["next"] as? [String]
      withKnownIssue("SI-238: Discovery currently ignores already-bound origin matches.") {
        #expect(foundNext == [Self.inspect])
        #expect(brief.stdout.contains(Self.inspect))
      }
      #expect(
        try FirstWorkspaceCommandTests.replay(Self.inspect, in: scratch, cwd: other).termination
          == .exit(0))
      #expect(try Self.identity(store) == before)
    }
  }

  @Test(arguments: [false, true])
  func explicitScopeRejectsDifferentConfiguredOrigins(bound: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try Self.declare("web", origin: Self.acmeOrigin, in: store)
      if bound {
        let held = try Self.clone("first/web", origin: Self.acmeOrigin, in: scratch)
        try Self.bind(held, in: scratch)
      }
      let repo = try Self.clone("second/web", origin: Self.otherOrigin, in: scratch)
      let before = try Self.identity(store)
      let result = try Self.run(["--ws", "acme", "init", "--scan", "."], repo, scratch)
      let after = try Self.identity(store)
      withKnownIssue("SI-238: Fallback currently binds a matching slug with a mismatched origin.") {
        #expect(result.termination == .exit(6))
        #expect(after == before)
      }
    }
  }

  @Test(arguments: [false, true])
  func explicitScopeBindsACompatibleGenericAliasOnlyWhenThePathIsFree(bound: Bool) throws {
    try withScratchDirectory { scratch in
      let declared = "https://git.acme.invalid/acme/web.git"
      let origin = "ssh://git@git.acme.invalid/acme/web.git"
      let store = try TaskCommandTests.setup(scratch)
      try Self.declare("web", origin: declared, in: store)
      if bound {
        let held = try Self.clone("first/web", origin: declared, in: scratch)
        try Self.bind(held, in: scratch)
      }
      let repo = try Self.clone("second/web", origin: origin, in: scratch)
      let before = try Self.identity(store)
      let result = try Self.run(["--ws", "acme", "init", "--scan", "."], repo, scratch)
      if bound {
        #expect(result.termination == .exit(6))
        #expect(try TaskStateCommandTests.error(result)["next"] as? [String] == [Self.inspect])
        #expect(try Self.identity(store) == before)
      } else {
        withKnownIssue("SI-238: An explicit scope currently refuses a compatible alias.") {
          #expect(result.termination == .exit(0))
        }
      }
    }
  }

  private static func declare(_ slug: String, origin: String? = nil, in store: DatabaseStore) throws
  {
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO repo(uid,workspace_id,slug,remote_url)
          SELECT 'repo-'||?,id,?,? FROM workspace WHERE slug='acme'
          """, arguments: [slug, slug, origin])
    }
  }

  private static func clone(_ leaf: String, origin: String, in scratch: URL) throws -> URL {
    let repo = scratch.appending(path: leaf)
    try InitCommandTests.makeRepo(repo, in: scratch)
    try InitCommandTests.git(["remote", "add", "origin", origin], in: scratch, cwd: repo)
    return repo
  }

  private static func bind(_ repo: URL, in scratch: URL) throws {
    let result = try run(["--ws", "acme", "init", "--scan", "."], repo, scratch)
    try #require(result.termination == .exit(0), "\(result.stdout)")
  }

  private static func identity(_ store: DatabaseStore) throws -> [Row] {
    try store.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT workspace.uid, workspace.slug, repo.uid, repo.slug, repo.remote_url, repo_path.path
          FROM repo JOIN workspace ON workspace.id=repo.workspace_id
          LEFT JOIN repo_path ON repo_path.repo_id=repo.id
          ORDER BY workspace.slug, repo.slug
          """)
    }
  }

  private static func run(_ args: [String], _ cwd: URL, _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      args + ["--json"], in: scratch, cwd: cwd, environment: TaskCommandTests.fixed)
  }
}
