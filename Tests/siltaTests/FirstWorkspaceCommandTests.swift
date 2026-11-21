import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct FirstWorkspaceCommandTests {
  static let origin = "https://example.invalid/acme/platform.git"

  @Test func emptyListingPointsAtScanningTheActualClone() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "Acme Work/platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      let nested = repo.appending(path: "src")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let listed = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch, cwd: nested)
      #expect(listed.termination == .exit(0))
      let data = try TaskStateCommandTests.data(listed)
      let next = try #require((data["next"] as? [String])?.first)
      #expect(next.hasPrefix("silta init --scan "))
      #expect(data["next_by"] as? String == "agent")
      let text = try SiltaBinary.run(["ws", "ls"], in: scratch, cwd: nested)
      #expect(text.stdout.contains("next: " + next))
      let scanned = try Self.replay(next, in: scratch, cwd: nested, json: true)
      try #require(scanned.termination == .exit(0), "\(scanned.stdout)\(scanned.stderr)")
      let receipt = try TaskStateCommandTests.data(scanned)
      #expect(receipt["workspace"] as? String == "platform")
      #expect(receipt["repositories"] as? [String] == ["platform"])
      #expect(receipt["apps"] as? [String] == ["platform"])
      let inspect = try #require((receipt["next"] as? [String])?.first)
      #expect(inspect == "silta --ws 'platform' ws show")
      #expect(try Self.replay(inspect, in: scratch, cwd: nested).termination == .exit(0))
      let located = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: nested)
      #expect(try TaskStateCommandTests.data(located)["workspace"] as? String == "platform")
      let final = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect((try TaskStateCommandTests.data(final)["workspaces"] as? [Any])?.count == 1)

      let human = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/script"),
        ["-q", "/dev/null", try SiltaBinary.url().path, "init", "--scan", "."],
        in: scratch, cwd: repo, environment: ["USER": "acme"])
      #expect(human.termination == .exit(0))
      #expect(human.stdout.contains("Edit from your terminal with silta ws edit 'platform'."))
      #expect(!human.stdout.contains("--approved"))
      let agent = try SiltaBinary.run(
        ["init", "--scan", "."], in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(agent.termination == .exit(0))
      #expect(agent.stdout.contains("Ask the human before editing the workspace configuration."))
      #expect(!agent.stdout.contains("--approved"))
    }
  }

  @Test func pathlessRegistrationOffersRepairBeforeCreatingAWorkspace() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "Acme Work/ac-platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(["remote", "add", "origin", Self.origin], in: scratch, cwd: repo)
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT 'acme-existing-repo',id,'declared-platform',? FROM workspace WHERE slug='acme'
            """, arguments: [Self.origin])
      }
      let whereResult = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: repo)
      let collision = try SiltaBinary.run(
        ["init", "--scan", repo.path, "--json"], in: scratch)
      #expect(whereResult.termination == .exit(2))
      #expect(collision.termination == .exit(6))
      let hints = try [whereResult, collision].map { result in
        let error = try TaskStateCommandTests.error(result)
        return try #require((error["next"] as? [String])?.first)
      }
      #expect(hints.allSatisfy { $0.hasPrefix("silta --ws 'acme' init --scan ") })
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 0)
      let repair = try #require(hints.first)
      let repaired = try Self.replay(repair, in: scratch, cwd: repo, json: true)
      try #require(repaired.termination == .exit(0), "\(repaired.stdout)\(repaired.stderr)")
      let receipt = try TaskStateCommandTests.data(repaired)
      #expect(receipt["repositories"] as? [String] == ["declared-platform"])
      let located = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: repo)
      #expect(try TaskStateCommandTests.data(located)["workspace"] as? String == "acme")
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM workspace") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM repo_path") == 1)
        #expect(try String.fetchOne(db, sql: "SELECT uid FROM repo") == "acme-existing-repo")
      }
    }
  }

  @Test func competingWorkspaceDeclarationsOnlyOfferInspection() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "renamed-platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(["remote", "add", "origin", Self.origin], in: scratch, cwd: repo)
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid, slug, name, task_prefix)
            VALUES ('other-workspace', 'other', 'Other', 'OT');
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT slug || '-platform',id,'declared-platform',? FROM workspace
            """, arguments: [Self.origin])
      }
      let expected = ["silta --ws 'acme' ws show", "silta --ws 'other' ws show"]
      for (args, code, exit) in [
        (["where"], "unregistered", 2), (["init", "--scan", "."], "conflict", 6),
      ] {
        let refusal = try SiltaBinary.run(args + ["--json"], in: scratch, cwd: repo)
        #expect(refusal.termination == .exit(Int32(exit)))
        let error = try TaskStateCommandTests.error(refusal)
        #expect(error["code"] as? String == code)
        let hints = try #require(error["next"] as? [String])
        #expect(hints == expected)
        for hint in hints {
          #expect(try Self.replay(hint, in: scratch, cwd: repo).termination == .exit(0))
        }
      }
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM workspace") == 2)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM repo_path") == 0)
      }
    }
  }

  @Test(arguments: [false, true])
  func partialOrRepeatedRepoMatchPreservesBindings(sameOrigin: Bool) throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "renamed")
      let platform = root.appending(path: "platform")
      let other = root.appending(path: "other")
      try InitCommandTests.makeRepo(platform, in: scratch)
      try InitCommandTests.makeRepo(other, in: scratch)
      try InitCommandTests.git(
        ["remote", "add", "origin", Self.origin], in: scratch, cwd: platform)
      if sameOrigin {
        try InitCommandTests.git(["remote", "add", "origin", Self.origin], in: scratch, cwd: other)
      }
      let first = try SiltaBinary.run(
        ["init", "--scan", platform.path, "--slug", "acme"], in: scratch)
      try #require(first.termination == .exit(0))
      let result = try SiltaBinary.run(["init", "--scan", root.path, "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      let hints = try TaskStateCommandTests.error(result)["next"] as? [String]
      #expect(hints == ["silta --ws 'acme' ws show"])
      let located = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: platform)
      #expect(try TaskStateCommandTests.data(located)["workspace"] as? String == "acme")
      let final = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect((try TaskStateCommandTests.data(final)["workspaces"] as? [Any])?.count == 1)
    }
  }

  @Test func derivedWorkspaceNameDoesNotMoveAnUnrelatedLiveBinding() throws {
    try withScratchDirectory { scratch in
      let original = scratch.appending(path: "original/acme")
      let unrelated = scratch.appending(path: "unrelated/acme")
      try InitCommandTests.makeRepo(original, in: scratch)
      try InitCommandTests.makeRepo(unrelated, in: scratch)
      let first = try SiltaBinary.run(["init", "--scan", "."], in: scratch, cwd: original)
      try #require(first.termination == .exit(0))
      let second = try SiltaBinary.run(
        ["init", "--scan", ".", "--json"], in: scratch, cwd: unrelated)
      let old = try SiltaBinary.run(["where"], in: scratch, cwd: original)
      let new = try SiltaBinary.run(["where"], in: scratch, cwd: unrelated)
      #expect(second.termination == .exit(6))
      #expect(old.termination == .exit(0))
      #expect(new.termination == .exit(2))
      let hints = try TaskStateCommandTests.error(second)["next"] as? [String]
      #expect(hints == ["silta --ws 'acme' ws show"])
    }
  }

  @Test func missingRootNamesThePathAndRefusesTheWholeScan() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "acme")
      let missing = scratch.appending(path: "Missing Acme")
      try InitCommandTests.makeRepo(repo, in: scratch)
      let result = try SiltaBinary.run(
        ["init", "--scan", repo.path, missing.path, "--json"], in: scratch)
      #expect(result.termination == .exit(1))
      let error = try TaskStateCommandTests.error(result)
      #expect((error["message"] as? String)?.contains(missing.path) == true)
      #expect(
        !FileManager.default.fileExists(
          atPath: scratch.appending(path: "silta-home/silta.db").path))
    }
  }

  @Test func missingFirstRootWithSpacesNamesItsFullPath() throws {
    try withScratchDirectory { scratch in
      let missing = scratch.appending(path: "Missing Acme")
      let result = try SiltaBinary.run(["init", "--scan", missing.path, "--json"], in: scratch)
      let error = try TaskStateCommandTests.error(result)
      #expect(result.termination == .exit(1) && error["code"] as? String == "invalid")
      #expect((error["message"] as? String)?.contains(missing.path) == true)
      #expect(error["next"] as? [String] == ["silta init --help"])
      #expect(error["next_by"] as? String == "agent")
      #expect(
        try Self.replay("silta init --help", in: scratch, cwd: scratch).termination == .exit(0))
    }
  }

  @Test func unreadableChildWarnsWhileItsSiblingIsRegistered() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "acme")
      let hidden = root.appending(path: "unreadable")
      try InitCommandTests.makeRepo(root.appending(path: "platform"), in: scratch)
      try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: hidden.path)  // Restore directory access.
      }
      let result = try SiltaBinary.run(["init", "--scan", root.path, "--json"], in: scratch)
      try #require(result.termination == .exit(0))
      #expect(
        try TaskStateCommandTests.data(result)["repositories"] as? [String] == ["platform"])
      #expect(try TaskStateCommandTests.warnings(result) == ["scan_skipped"])
      #expect(result.stdout.contains(hidden.path))
    }
  }

  private static func canonicalPath(_ directory: URL) throws -> String {
    let values = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values.volumeSupportsCaseSensitiveNames == false
      ? directory.path.lowercased() : directory.path
  }

  static func replay(_ hint: String, in scratch: URL, cwd: URL, json: Bool = false) throws
    -> CLIResult
  {
    let binary = shellWord(try SiltaBinary.url().path)
    let command = binary + (json ? " --json" : "") + String(hint.dropFirst("silta".count))
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"), ["-c", command], in: scratch, cwd: cwd)
  }
}

extension FirstWorkspaceCommandTests {
  @Test(arguments: [false, true])
  func whereFindsAPathlessCloneDeclaration(withRemote: Bool) throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "ac-platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(
        ["remote", "add", "origin", "git@github.com:acme-fixture-org/probe-platform.git"],
        in: scratch, cwd: repo
      )
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT 'acme-existing-repo',id,?,? FROM workspace WHERE slug='acme'
            """,
          arguments: [
            withRemote ? "declared-platform" : "ac-platform",
            withRemote ? "https://GITHUB.com/acme-fixture-org/probe-platform" : nil,
          ])
      }
      let result = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: repo)
      let error = try TaskStateCommandTests.error(result)
      let next = try #require((error["next"] as? [String])?.first)
      let prefix = "silta --ws 'acme' init --scan "
      let inspect = "silta --ws 'acme' ws show"
      #expect(withRemote ? next.hasPrefix(prefix) : next == inspect)
      let brief = try SiltaBinary.run(["brief", "--json"], in: scratch, cwd: repo)
      #expect(brief.stdout.contains(withRemote ? prefix : inspect))
      let scan = try SiltaBinary.run(["init", "--scan", ".", "--json"], in: scratch, cwd: repo)
      #expect(scan.termination == .exit(6))
      let scanHint = try #require(
        try (TaskStateCommandTests.error(scan)["next"] as? [String])?.first)
      #expect(withRemote ? scanHint.hasPrefix(prefix) : scanHint == inspect)
      for hint in [next, scanHint] {
        let repaired = try Self.replay(hint, in: scratch, cwd: repo)
        #expect(repaired.termination == .exit(0), "\(repaired.stderr)")
      }
      if !withRemote {
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 0)
        let selected = try SiltaBinary.run(
          ["--ws", "acme", "init", "--scan", ".", "--json"], in: scratch, cwd: repo)
        #expect(selected.termination == .exit(0), "\(selected.stdout)")
      }
      let canonical = try Self.canonicalPath(repo)
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM workspace") == 1)
        #expect(try String.fetchOne(db, sql: "SELECT uid FROM repo") == "acme-existing-repo")
        #expect(
          try String.fetchOne(db, sql: "SELECT path FROM repo_path") == canonical)
      }
    }
  }

  @Test func competingOriginsAndPathlessSlugsRequireInspectionUntilAnExactPathExists() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "ac-platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(
        ["remote", "add", "origin", "git@github.com:acme-fixture-org/probe-platform.git"],
        in: scratch, cwd: repo
      )
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT 'repo-origin',id,'declared-platform',? FROM workspace WHERE slug='acme';
            INSERT INTO repo(uid,workspace_id,slug)
            SELECT 'repo-slug',id,'ac-platform' FROM workspace WHERE slug='acme'
            """, arguments: ["https://github.com/acme-fixture-org/probe-platform.git"])
      }
      let arguments = ["--ws", "acme", "init", "--scan", ".", "--json"]
      let refusal = try SiltaBinary.run(arguments, in: scratch, cwd: repo)
      #expect(refusal.termination == .exit(6))
      #expect(
        try TaskStateCommandTests.error(refusal)["next"] as? [String] == [
          "silta --ws 'acme' ws show"
        ])
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 0)
      try store.write { tx in
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo WHERE uid='repo-origin'",
          arguments: [try Self.canonicalPath(repo)])
      }
      let exact = try SiltaBinary.run(arguments, in: scratch, cwd: repo)
      try #require(exact.termination == .exit(0), "\(exact.stdout)")
      #expect(
        try TaskStateCommandTests.data(exact)["repositories"] as? [String] == ["declared-platform"])
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 1)
    }
  }

  @Test(arguments: [
    "https://github.com:8443/acme-fixture-org/probe-platform.git"
  ])
  func differentHostedOriginsDoNotMatch(declaredOrigin: String) throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "ac-platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(
        ["remote", "add", "origin", "https://github.com/acme-fixture-org/probe-platform.git"],
        in: scratch, cwd: repo)
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT 'repo-origin',id,'declared-platform',? FROM workspace WHERE slug='acme'
            """, arguments: [declaredOrigin])
      }
      let result = try SiltaBinary.run(["init", "--scan", ".", "--json"], in: scratch, cwd: repo)
      #expect(result.termination == .exit(6))
      let error = try TaskStateCommandTests.error(result)
      #expect(error["next"] as? [String] == ["silta --ws 'acme' ws show", "silta init --help"])
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 0)
    }
  }

  @Test func possibleAliasOnAGenericHostOffersInspectionWithoutBinding() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "ac-platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(
        ["remote", "add", "origin", "git@example.invalid:acme/platform.git"], in: scratch, cwd: repo
      )
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT 'acme-existing-repo',id,'declared-platform',? FROM workspace WHERE slug='acme'
            """, arguments: ["ssh://git@example.invalid/acme/platform.git"])
      }
      let cases = [
        (["where"], Int32(2)),
        (["init", "--scan", "."], Int32(6)),
        (["--ws", "acme", "init", "--scan", "."], Int32(6)),
      ]
      let inspect = "silta --ws 'acme' ws show"
      for (args, exit) in cases {
        let result = try SiltaBinary.run(args + ["--json"], in: scratch, cwd: repo)
        #expect(result.termination == .exit(exit))
        #expect(try TaskStateCommandTests.error(result)["next"] as? [String] == [inspect])
      }
      #expect(try Self.replay(inspect, in: scratch, cwd: repo).termination == .exit(0))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 1)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 0)
    }
  }

  @Test func emptyScanDoesNotCreateAWorkspaceOrDatabase() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["init", "--scan", ".", "--json"], in: scratch)
      #expect(result.termination == .exit(1))
      let error = try TaskStateCommandTests.error(result)
      #expect(error["code"] as? String == "invalid")
      #expect(error["next"] as? [String] == ["silta init --help"])
      #expect(
        try Self.replay("silta init --help", in: scratch, cwd: scratch).termination == .exit(0))
      #expect(
        !FileManager.default.fileExists(
          atPath: scratch.appending(path: "silta-home/silta.db").path))
    }
  }
}
