import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct TaskMapUnlinkCommandTests {
  @Test func unlinkPreservesEachOtherReferenceAndAllowsTheFinalMapEdit() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "app", in: store)
      let console = "apps: [{slug: console, repo: platform, ref: other}"
      let twoApps = AcmeDocAttachments.yaml().replacingOccurrences(
        of: "apps: [", with: console + ", ")
      try AcmeDocAttachments.apply(twoApps, to: store)
      try seedTasks(store)
      for (ref, target, relation) in [
        ("AC-1", "app:api", "about"), ("AC-1", "app:api", "cites"),
        ("AC-2", "app:api", "about"), ("AC-1", "topic:messaging", "about"),
        ("AC-1", "app:console", "about"),
      ] {
        try success(["task", "link", ref, target, "--rel", relation], scratch)
      }
      let yaml = AcmeDocAttachments.yaml(removing: "app").replacingOccurrences(
        of: "apps: []", with: console + "]")
      let file = scratch.appending(path: "remove-api.yml")
      try yaml.write(to: file, atomically: true, encoding: .utf8)
      let edit = ["ws", "edit", "-F", file.path, "--approved", "Remove unused Acme app.", "--json"]
      let before = try identities(store)
      let blocked = try run(edit, scratch)
      #expect(try TaskStateCommandTests.error(blocked)["code"] as? String == "conflict")

      let error = try TaskStateCommandTests.error(blocked)
      let next = try #require(error["next"] as? [String])
      #expect(next.contains("silta --ws 'acme' task show 'AC-1'"))
      #expect(next.allSatisfy { !$0.contains("task unlink") })
      let shown = try run(["task", "show", "AC-1"], scratch)
      #expect(shown.stdout.contains("about: app:api"))
      let first = try run(
        ["task", "unlink", "AC-1", "app:api", "--rel", "about", "--json"], scratch)
      try #require(first.termination == .exit(0), "\(first.stdout)\(first.stderr)")
      Golden.forTests().check(first.stdout, "task-unlink.json")
      #expect(try identities(store) == before.filter { $0 != "task|1|about|app|1" })
      let audit = try changeState(store)
      let repeated = try run(
        ["task", "unlink", "AC-1", "app:api", "--rel", "about"],
        scratch, now: "2023-11-15T22:13:20.000Z")
      #expect(repeated.termination == .exit(0))
      #expect(repeated.stdout.contains("no matching"))
      #expect(try changeState(store) == audit)
      #expect(try run(edit, scratch).termination == .exit(6))

      try releaseRemainingPins(andApply: edit, in: scratch)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app") } == 1)
    }
  }

  @Test func legacyTargetsCanBePastedFromTaskShow() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try seedTasks(store)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE service SET slug='push/legacy %雪';
            UPDATE edge SET kind='HTTP/API %2F 雪';
            INSERT INTO link(
              uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
              VALUES('old-service',1,'task',1,'cites','service',1,'human:acme',''),
                    ('old-edge',1,'task',1,'cites','edge',1,'human:acme','');
            """)
      }
      let shown = try run(["task", "show", "AC-1", "--json"], scratch)
      let data = try GuideContractTests.data(shown)
      let links = try #require(data["links"] as? [[String: String]])
      try #require(links.count == 2)
      for link in links {
        let target = try #require(link["target"])
        #expect(target.contains("%2F"))
        try success(["task", "unlink", "AC-1", target], scratch)
      }
      #expect(try identities(store).isEmpty)
    }
  }

  private func releaseRemainingPins(andApply edit: [String], in scratch: URL) throws {
    try success(["task", "unlink", "AC-1", "app:api"], scratch)
    try success(["task", "unlink", "AC-2", "app:api", "--rel", "about"], scratch)
    #expect(try run(edit, scratch).termination == .exit(6))
    try success(["doc", "archive", "rules", "--approved", "Archive the Acme rules."], scratch)
    let assignment = try run(edit, scratch)
    #expect(assignment.termination == .exit(6))
    #expect(assignment.stdout.contains("AC-3"))
    try success(
      ["task", "edit", "AC-3", "--app", "none", "--approved", "Unassign the Acme app."],
      scratch)
    try success(edit, scratch)
  }

  @Test func guardedRequestsLeaveTheMapLinkIntact() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try seedTasks(store)
      try success(["task", "link", "AC-2", "app:api"], scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET status='doing', claimed_by='agent:codex:other',
              claimed_at='2023-11-14T22:13:20.000Z' WHERE seq=2;
            """)
      }
      let args = ["task", "unlink", "AC-2", "app:api", "--json"]
      let foreign = try run(args, scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET external_ref='ado:42',claimed_by=NULL,claimed_at=NULL WHERE seq=2;
            """)
      }
      let promoted = try run(args, scratch)
      #expect(try TaskStateCommandTests.error(foreign)["code"] as? String == "claimed")
      #expect(
        try TaskStateCommandTests.error(promoted)["code"] as? String == "read_only_promoted")
      let relation = try run(args + ["--rel", "blocked_by"], scratch)
      #expect(try TaskStateCommandTests.error(relation)["code"] as? String == "invalid")
      let notMap = try run(
        ["task", "unlink", "AC-1", "url:https://example.invalid", "--json"], scratch)
      #expect(try TaskStateCommandTests.error(notMap)["code"] as? String == "invalid")
      #expect(try identities(store) == ["task|2|cites|app|1"])
    }
  }

  private func seedTasks(_ store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO task(id,uid,workspace_id,seq,title,status,app_id,archive_override,
            created_by,created_at,updated_at)
          VALUES(1,'acme-1',1,1,'Acme closed','done',NULL,'archived','human:acme','',''),
                (2,'acme-2',1,2,'Acme check','todo',NULL,NULL,'human:acme','',''),
                (3,'acme-3',1,3,'Acme app','todo',1,NULL,'human:acme','','');
          """)
    }
  }

  private func identities(_ store: DatabaseStore) throws -> [String] {
    try store.read {
      try String.fetchAll(
        $0,
        sql: """
          SELECT from_kind || '|' || from_id || '|' || rel || '|' || to_kind || '|' || to_id
          FROM link ORDER BY from_kind, from_id, rel, to_kind, to_id
          """)
    }
  }

  private func changeState(_ store: DatabaseStore) throws -> [String] {
    try store.read {
      try String.fetchAll(
        $0,
        sql: """
          SELECT updated_at FROM task WHERE id=1
          UNION ALL SELECT kind || '|' || COALESCE(body,'') FROM task_event WHERE task_id=1
          """)
    }
  }

  private func run(
    _ args: [String], _ scratch: URL, now: String = "2023-11-14T22:13:20.000Z"
  ) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", "acme"] + args, in: scratch,
      environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": now])
  }

  private func success(_ args: [String], _ scratch: URL) throws {
    let result = try run(args, scratch)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
  }
}
