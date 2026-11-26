import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct WorkspaceRenameCommandTests {
  private static let initial = """
    workspace: {slug: acme, name: Acme, task_prefix: AC}
    repos: [{slug: platform}]
    apps: [{slug: api, name: Acme API, repo: platform, ref: origin/main}]
    environments: [{app: api, name: prod}]
    services: [push]
    edges:
      - from: api
        to: service:push
        kind: sdk
        summary: Push
        code: ['code:api@origin/main:readme#L1']
    topics: [{slug: messaging, aliases: [Messages]}]
    """ + "\n"

  private static let renamed =
    initial
    .replacingOccurrences(of: "slug: api, ", with: "slug: delivery, previous: [api], ")
    .replacingOccurrences(
      of: "slug: messaging, ", with: "slug: delivery-design, previous: [messaging], ")

  @Test func previewAndSavePreserveAttachedIdentityAndResolveTheOldNames() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.apply(Self.initial, to: store)
      let repo = scratch.appending(path: "platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      let scan = try Self.run(["init", "--scan", repo.path], in: scratch)
      try #require(scan.termination == .exit(0), "\(scan.stderr)")
      for kind in ["app", "topic", "edge"] {
        try AcmeDocAttachments.attach("delivery-guide", to: kind, in: store)
      }
      let task = try Self.run(
        ["task", "add", "Deliver notices", "--app", "api", "--topic", "messaging", "--json"],
        in: scratch, cwd: repo)
      try #require(task.termination == .exit(0), "\(task.stdout)\(task.stderr)")
      let reference = try #require(try TaskStateCommandTests.data(task)["ref"] as? String)
      let override = try Self.run(
        ["where", "--set", "api", "--approved", "Use the Acme API app"], in: scratch, cwd: repo)
      try #require(override.termination == .exit(0), "\(override.stderr)")
      let before = try Self.attachedState(store)
      let approvals = try Self.approvals(store)
      let snapshot = try Self.show(in: scratch)
      let input = String(snapshot.prefix(while: { $0 != "\n" })) + "\n" + Self.renamed
      try Self.checkPreview(input, in: scratch)
      #expect(try Self.show(in: scratch) == snapshot)
      #expect(try Self.attachedState(store) == before)
      #expect(try Self.approvals(store) == approvals)
      let saved = try Self.edit(input, flags: Self.approval, in: scratch)
      try #require(saved.termination == .exit(0), "\(saved.stdout)\(saved.stderr)")
      #expect(saved.stdout.contains("api -> delivery"))
      #expect(try Self.attachedState(store) == before)
      #expect(try Self.approvals(store) == approvals + 1)
      try Self.checkOldReferences(reference, repo: repo, in: scratch)
      let after = try Self.show(in: scratch)
      #expect(after.contains(#""previous":["api"]"#))
      #expect(after.contains(#""previous":["messaging"]"#))
      #expect(after.contains("code:delivery@origin/main:readme#L1"))
      #expect(try Self.edit(after, flags: Self.approval, in: scratch).stdout == "No changes.\n")
      let other = try Self.restore(in: scratch)
      #expect(try Self.show(in: scratch, environment: other).contains(#""previous":["api"]"#))
      let restored = try Self.run(
        ["task", "ls", "--app", "api", "--proposed", "--json"], in: scratch, environment: other)
      #expect(try TaskStateCommandTests.tasks(restored).count == 1)
      #expect(try TaskStateCommandTests.warnings(restored).contains("renamed"))
    }
  }

  @Test func replacementRowMakesAnIdenticalLookingStampedDraftStale() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let old = try Self.show(in: scratch)
      let uid = try store.read { try String.fetchOne($0, sql: "SELECT uid FROM app") }
      let removed = try Self.edit(
        AcmeDocAttachments.yaml(removing: "app"), flags: Self.approval, in: scratch)
      try #require(removed.termination == .exit(0), "\(removed.stderr)")
      let replaced = try Self.edit(AcmeDocAttachments.yaml(), flags: Self.approval, in: scratch)
      try #require(replaced.termination == .exit(0), "\(replaced.stderr)")
      let fresh = try Self.show(in: scratch)
      #expect(fresh.split(separator: "\n").dropFirst() == old.split(separator: "\n").dropFirst())
      #expect(fresh != old)
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT uid FROM app") } != uid)
      let draft = old.replacingOccurrences(
        of: #""slug":"api""#, with: #""slug":"delivery","previous":["api"]"#)
      let stale = try Self.edit(draft, flags: ["--dry-run", "--json"], in: scratch)
      #expect(stale.termination == .exit(6))
      #expect(
        try TaskStateCommandTests.error(stale)["next"] as? [String] == ["silta --ws 'acme' ws show"]
      )
      #expect(try Self.show(in: scratch) == fresh)
    }
  }

  @Test func previewAndSaveFindAllRemovalBlockers() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      for kind in ["app", "edge", "topic"] {
        try AcmeDocAttachments.attach("delivery-guide", to: kind, in: store)
      }
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,
              created_by,created_at,updated_at)
            SELECT 'task-'||n,workspace_id,n,'Acme work','todo',id,'human:acme','x','x'
            FROM app CROSS JOIN (SELECT 1 AS n UNION SELECT 2);
            INSERT INTO worktree_override(path,app_id,set_by)
            SELECT '/acme/worktree',id,'human:acme' FROM app;
            INSERT INTO source(uid,workspace_id,kind,root,include,repo_id)
            SELECT 'source-acme',workspace_id,'notes','all','[]',id FROM repo;
            """)
      }
      let before = try Self.show(in: scratch)
      let offered = """
        workspace: {slug: acme, name: Acme, task_prefix: AC}
        sources: [{kind: notes, root: all, include: []}]
        """ + "\n"
      let dry = try Self.edit(offered, flags: ["--dry-run"], in: scratch)
      #expect(dry.termination == .exit(0))
      let refused = try Self.edit(offered, flags: Self.approval, in: scratch)
      #expect(refused.termination == .exit(6))
      for ref in [
        "app:api", "edge:api/service:push/sdk", "topic:messaging", "doc:delivery-guide", "AC-1",
        "AC-2", "worktree override", "source:notes/all",
      ] {
        #expect(dry.stdout.contains(ref), "\(dry.stdout)\(dry.stderr)")
        #expect(refused.stderr.contains(ref), "\(refused.stderr)")
      }
      #expect(try Self.approvals(store) == 0)
      #expect(try Self.show(in: scratch) == before)
    }
  }

  @Test func historicalNamesStayReservedAfterRemovalAndRestore() throws {
    try withScratchDirectory { scratch in
      _ = try AcmeDocAttachments.make(in: scratch)
      let rename = AcmeDocAttachments.yaml().replacingOccurrences(
        of: "slug: api, ", with: "slug: delivery, previous: [api], ")
      let duplicate =
        rename + "environments: [{app: api, name: prod}, {app: delivery, name: prod}]\n"
      let conflict = try Self.edit(duplicate, flags: ["--dry-run"], in: scratch)
      #expect(conflict.termination == .exit(1))
      #expect(conflict.stderr.contains("duplicate environments"))
      let relabeled = try Self.edit(rename, flags: Self.approval, in: scratch)
      try #require(relabeled.termination == .exit(0), "\(relabeled.stderr)")
      let removed = try Self.edit(
        AcmeDocAttachments.yaml(removing: "app"), flags: Self.approval, in: scratch)
      try #require(removed.termination == .exit(0), "\(removed.stderr)")
      let other = try Self.restore(in: scratch)
      let reused = try Self.edit(
        AcmeDocAttachments.yaml(), flags: ["--dry-run"], in: scratch, environment: other)
      #expect(reused.termination == .exit(1))
      #expect(reused.stderr.contains("api"))
      #expect(reused.stderr.contains("--dry-run"))
      #expect(!reused.stderr.contains("--approved"))
    }
  }

  private static func checkPreview(_ input: String, in scratch: URL) throws {
    let dry = try edit(input, flags: ["--dry-run", "--json"], in: scratch)
    try #require(dry.termination == .exit(0), "\(dry.stdout)\(dry.stderr)")
    let text = try edit(input, flags: ["--dry-run"], in: scratch)
    #expect(text.termination == .exit(0))
    Golden.forTests().check(dry.stdout, "ws-edit-rename-preview.json")
    Golden.forTests().check(text.stdout, "ws-edit-rename-preview.txt")
    let schema = try SiltaBinary.run(["schema", "ws", "edit", "--json"], in: scratch)
    let commands = try #require(
      try TaskStateCommandTests.data(schema)["commands"] as? [[String: Any]])
    let shape = try #require(commands.first?["data"])
    let preview = try TaskStateCommandTests.data(dry)
    #expect(preview["dry_run"] as? Bool == true)
    #expect(ShapeCheck.violations(of: preview, against: shape).isEmpty)
    let changes = try #require(preview["changes"] as? [String: Any])
    let renames = try #require(changes["renamed"] as? [[String: Any]])
    #expect(renames.compactMap { $0["to"] as? String } == ["delivery", "delivery-design"])
    #expect(renames.first?["docs"] as? Int == 1)
    #expect(renames.first?["tasks"] as? Int == 1)
    #expect(renames.first?["edges"] as? Int == 1)
    #expect(renames.first?["environments"] as? Int == 1)
  }

  private static func checkOldReferences(_ reference: String, repo: URL, in scratch: URL) throws {
    let oldWhere = try Self.run(["where", "--app", "api", "--json"], in: scratch, cwd: repo)
    let oldCode = try Self.run(
      ["code", "show", "api@origin/main", "--json", "--", "readme"], in: scratch, cwd: repo)
    let oldTask = try Self.run(
      ["task", "ls", "--app", "api", "--topic", "messaging", "--proposed", "--json"],
      in: scratch, cwd: repo)
    let oldDoc = try Self.run(
      ["doc", "ls", "--about", "topic:messaging", "--json"], in: scratch)
    for output in [oldWhere, oldCode, oldTask, oldDoc] {
      #expect(output.termination == .exit(0), "\(output.stdout)\(output.stderr)")
      #expect(try TaskStateCommandTests.warnings(output).contains("renamed"), "\(output.stdout)")
    }
    #expect(try TaskStateCommandTests.data(oldWhere)["app"] as? String == "delivery")
    #expect(try TaskStateCommandTests.data(oldCode)["app"] as? String == "delivery")
    #expect(
      try TaskStateCommandTests.tasks(oldTask).compactMap { $0["ref"] as? String } == [reference])
    #expect(oldDoc.stdout.contains("doc:delivery-guide"))
  }

  private static let approval = ["--approved", "Apply the Acme workspace change"]

  private static func approvals(_ store: DatabaseStore) throws -> Int {
    try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") ?? 0 }
  }

  private static func attachedState(_ store: DatabaseStore) throws -> [[Row]] {
    let projections = [
      "SELECT id,uid FROM app", "SELECT id,uid FROM topic", "SELECT id,uid,app_id FROM task",
      "SELECT id,uid,app_id FROM environment", "SELECT id,uid,from_app_id,to_service_id FROM edge",
      "SELECT * FROM link ORDER BY id", "SELECT * FROM doc_rev ORDER BY id",
      "SELECT * FROM worktree_override",
    ]
    return try store.read { db in try projections.map { try Row.fetchAll(db, sql: $0) } }
  }

  private static func run(
    _ args: [String], in scratch: URL, cwd: URL? = nil,
    environment: [String: String] = TaskCommandTests.fixed
  ) throws -> CLIResult {
    try SiltaBinary.run(["--ws", "acme"] + args, in: scratch, cwd: cwd, environment: environment)
  }

  private static func show(in scratch: URL, environment: [String: String] = TaskCommandTests.fixed)
    throws -> String
  {
    let result = try run(["ws", "show"], in: scratch, environment: environment)
    try #require(result.termination == .exit(0), "\(result.stderr)")
    return result.stdout
  }

  private static func edit(
    _ yaml: String, flags: [String], in scratch: URL,
    environment: [String: String] = TaskCommandTests.fixed
  ) throws -> CLIResult {
    let file = scratch.appending(path: "workspace-edit.yaml")
    try yaml.write(to: file, atomically: true, encoding: .utf8)
    return try run(["ws", "edit", "-F", file.path] + flags, in: scratch, environment: environment)
  }

  private static func restore(in scratch: URL) throws -> [String: String] {
    let export = try run(["export", "--to", "out"], in: scratch)
    try #require(export.termination == .exit(0), "\(export.stderr)")
    let env = TaskCommandTests.fixed.merging([
      "SILTA_HOME": scratch.appending(path: "restored-home").path
    ]) { $1 }
    let restored = try SiltaBinary.run(
      ["restore", "out/acme", "--approved", "Restore the Acme workspace"], in: scratch,
      environment: env)
    try #require(restored.termination == .exit(0), "\(restored.stderr)")
    return env
  }
}

extension WorkspaceRenameCommandTests {
  @Test func formerAppAndTopicOptionsCarryWarningsAndLinkOnlyOnce() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.apply(Self.initial, to: store)
      let repo = scratch.appending(path: "platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      let scan = try Self.run(["init", "--scan", repo.path], in: scratch)
      try #require(scan.termination == .exit(0), "\(scan.stderr)")
      let saved = try Self.edit(Self.renamed, flags: Self.approval, in: scratch)
      try #require(saved.termination == .exit(0), "\(saved.stderr)")
      for command in [
        ["where", "--set", "api", "--approved", "Use the Acme app"],
        ["brief", "--app", "api", "--topic", "messaging"],
        [
          "task", "add", "Fix delivery", "--app", "api", "--topic", "messaging", "--topic",
          "delivery-design",
        ],
      ] {
        let result = try Self.run(command + ["--json"], in: scratch, cwd: repo)
        #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        #expect(try TaskStateCommandTests.warnings(result).contains("renamed"))
      }
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE to_kind='topic'") == 1)
      }
    }
  }

  @Test func ambiguousLegacyNamesFailClosedAndCannotBeRestored() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref,previous_slugs)
            SELECT 'acme-unrelated',workspace_id,'delivery','Delivery',repo_id,'other','["api"]'
            FROM app;
            """)
      }
      let listed = try Self.run(["task", "ls", "--app", "api", "--json"], in: scratch)
      #expect(listed.termination == .exit(1))
      #expect(
        try TaskStateCommandTests.error(listed)["next"] as? [String] == [
          "silta --ws 'acme' ws show"
        ])
      let export = try Self.run(["export", "--to", "out"], in: scratch)
      try #require(export.termination == .exit(0), "\(export.stderr)")
      let target = scratch.appending(path: "restored-home")
      let result = try SiltaBinary.run(
        ["restore", "out/acme", "--dry-run", "--json"], in: scratch,
        environment: ["SILTA_HOME": target.path])
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("conflicting or reserved ownership"))
      #expect(!FileManager.default.fileExists(atPath: target.appending(path: "silta.db").path))
    }
  }

  @Test func exactCurrentTopicStillWinsOverOrdinaryAliasAfterRestore() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("alias-doc", to: "topic", in: store)
      try AcmeDocAttachments.apply(
        AcmeDocAttachments.yaml().replacingOccurrences(
          of: "{slug: messaging}", with: "{slug: messaging, aliases: [alerts]}, {slug: alerts}"),
        to: store)
      let env = try Self.restore(in: scratch)
      let exact = try Self.run(
        ["doc", "ls", "--about", "topic:alerts", "--json"], in: scratch, environment: env)
      #expect(exact.termination == .exit(0))
      #expect(try TaskStateCommandTests.data(exact)["total"] as? Int == 0)
      let ordinary = try Self.run(
        ["doc", "ls", "--about", "topic:messaging", "--json"], in: scratch, environment: env)
      #expect(ordinary.stdout.contains("doc:alias-doc"))
    }
  }
}

extension WorkspaceRenameCommandTests {
  @Test func invalidStdinPreviewKeepsAReadOnlyRetry() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let shown = try Self.show(in: scratch)
      let binary = shellWord(try SiltaBinary.url().path)
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c",
          "printf '%s\\n' 'workspace: []' | \(binary) --ws acme ws edit --dry-run -F - --json",
        ],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(1))
      let error = try TaskStateCommandTests.error(result)
      #expect(error["code"] as? String == "invalid")
      #expect(error["next_by"] as? String == "agent")
      #expect(
        error["next"] as? [String] == [
          "silta ws show 'acme'", "silta ws edit 'acme' --dry-run -F -",
        ])
      #expect(try Self.approvals(store) == 0)
      #expect(try Self.show(in: scratch) == shown)
    }
  }
}

extension WorkspaceRenameCommandTests {
  @Test func oneItemWithDocumentAndTaskBlockersKeepsRecoveryReadOnly() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("delivery-guide", to: "app", in: store)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,
              created_by,created_at,updated_at)
            SELECT 'task-acme',workspace_id,1,'Acme work','todo',id,'human:acme','x','x'
            FROM app;
            """)
      }
      let before = try Self.show(in: scratch)
      let refused = try Self.edit(
        AcmeDocAttachments.yaml(removing: "app"), flags: Self.approval + ["--json"],
        in: scratch)
      #expect(refused.termination == .exit(6))
      let error = try TaskStateCommandTests.error(refused)
      #expect(error["next_by"] as? String == "agent")
      #expect(
        error["next"] as? [String] == [
          "silta --ws 'acme' task show 'AC-1'", "silta --ws 'acme' doc ls",
          "silta --ws 'acme' ws show",
        ])
      let message = try #require(error["message"] as? String)
      #expect(message.contains("app:api (AC-1, doc:delivery-guide)"))
      #expect(try Self.approvals(store) == 0)
      #expect(try Self.show(in: scratch) == before)
    }
  }

  @Test func oldAndCurrentCodeLinkSpellingKeepTheOriginalLinkAndHistory() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let added = try Self.run(["task", "add", "Check readme", "--app", "none"], in: scratch)
      try #require(added.termination == .exit(0), "\(added.stderr)")
      let first = try Self.run(
        ["task", "link", "AC-1", "code:api@origin/main:readme#L1"], in: scratch)
      try #require(first.termination == .exit(0), "\(first.stderr)")
      let before = try Self.codeLinks(store)
      let rename = AcmeDocAttachments.yaml().replacingOccurrences(
        of: "slug: api, ", with: "slug: delivery, previous: [api], ")
      let saved = try Self.edit(rename, flags: Self.approval, in: scratch)
      try #require(saved.termination == .exit(0), "\(saved.stderr)")
      for owner in ["api", "delivery"] {
        let repeated = try Self.run(
          ["task", "link", "AC-1", "\(owner)@origin/main:readme#L1", "--json"],
          in: scratch)
        #expect(repeated.termination == .exit(0))
        #expect(
          try TaskStateCommandTests.warnings(repeated).contains("renamed") == (owner == "api"))
        #expect(try Self.codeLinks(store) == before)
      }
      let distinct = try Self.run(
        ["task", "link", "AC-1", "delivery@origin/main:readme#L2"], in: scratch)
      #expect(distinct.termination == .exit(0))
      #expect(try Self.codeLinks(store).allSatisfy { $0.count == 2 })
    }
  }

  private static func codeLinks(_ store: DatabaseStore) throws -> [[Row]] {
    try store.read { db in
      [
        try Row.fetchAll(db, sql: "SELECT * FROM link WHERE to_kind='code' ORDER BY id"),
        try Row.fetchAll(db, sql: "SELECT * FROM task_event WHERE kind='link' ORDER BY id"),
      ]
    }
  }
}
