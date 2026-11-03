import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskLinkTests {
  static func seed(_ service: TaskService) throws {
    try service.environment.db.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO repo(uid,workspace_id,slug) VALUES('acme-repo',1,'platform');
          INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
            VALUES('acme-app',1,'platform','Acme',1,'main');
          INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES('acme-doc',1,'guide','Acme','guide','','');
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
            VALUES('acme-rev',1,4,'Acme','accepted','human:acme','');
          INSERT INTO comment(uid,task_id,seq,kind,body_md,actor,created_at)
            VALUES('acme-comment',1,3,'question','Acme','human:acme','');
          INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
            VALUES('acme-doc-comment',1,2,'question','Acme','human:acme','');
          INSERT INTO workspace(uid,slug,name,task_prefix)
          VALUES('acme-beta','beta','Acme beta','BE');
          INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES('acme-foreign-doc',2,'foreign','Acme','guide','','');
          """)
    }
  }

  @Test func parseStoreAndRenderOwnedAndExternalTargets() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      _ = try await TaskOrganizationTests.add(service, directory: home)
      try Self.seed(service)
      _ = try service.plan("AC-1", text: "Acme first\nAcme second")
      let targets = [
        "AC-2": "task:AC-2", "task:AC-2": "task:AC-2", "AC-1/3": "AC-1/3",
        "doc:guide": "doc:guide", "doc:guide@4": "doc:guide@4",
        "doc:guide@4/2": "doc:guide@4/2", "app:platform": "app:platform",
        "topic:release": "topic:release", "plan#L1": "plan#L1",
        "plan@1#L1": "plan@1#L1", "plan@1#L2": "plan@1#L2",
        "code:platform:src/Acme.swift#L1-2": "code:platform:src/Acme.swift#L1-2",
        "platform@feature/acme:src/Acme.swift": "code:platform@feature/acme:src/Acme.swift",
        "note:notes/acme.md": "note:notes/acme.md",
        "url:https://example.com/acme#42": "url:https://example.com/acme#42",
      ]
      for target in targets.keys.sorted() { _ = try service.link("AC-1", target: target) }
      let links = try service.show("AC-1").links
      #expect(Set(links.map(\.target)) == Set(targets.values))
      let before = try TaskOrganizationTests.counts(service)
      for target in targets.keys { _ = try service.link("task:AC-1", target: target) }
      #expect(try TaskOrganizationTests.counts(service) == before)
      try service.environment.db.read { db in
        let owned = try Row.fetchAll(
          db, sql: "SELECT * FROM link WHERE to_kind NOT IN ('code','url','note')")
        #expect(owned.count == 10)
        #expect(
          owned.allSatisfy { ($0["created_by"] as String) == TaskServiceTests.agent.description })
        #expect(
          owned.allSatisfy { ($0["to_id"] as Int64?) != nil && ($0["to_ext"] as String?) == nil })
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE to_kind='task_plan_rev'") == 2)
      }
      try Self.checkInvalidReferences(service)
      #expect(try TaskOrganizationTests.counts(service) == before)
    }
  }

  private static func checkInvalidReferences(_ service: TaskService) throws {
    for invalid in [
      "doc:foreign", "doc:guide@3", "doc:guide@4/1", "doc:guide/2", "doc:guide@04",
      "AC-1/3/4", "doc:guide@4/2/3", "doc:guide@4@5",
      "code:platform", "platform:", "platform:Acme.swift#L1#L2",
      "platform:Acme\\file.swift", "platform:Acme\nfile.swift",
      "plan@#L1", "plan@0#L1", "plan#XL1", "platform:Acme.swift#XL1",
      "AC-1/2", "AC-1/03", "AC-1/0", "BE-1", "AC-9", "app:missing", "topic:missing",
      "plan#L0", "plan#L3", "plan#L2-1", "plan@2#L1", "plan@1#L1-3",
      "platform:../Acme.swift", "platform:/Acme.swift", "platform:Acme.swift#L0",
      "platform@:Acme.swift", "platform:Acme.swift#L2-1", "platform:Acme.swift#L01",
      "url:ftp://example.com/acme", "url:file:///tmp/acme", "url:https://user:pwd@example.com",
      "url:https://",
      "note:", "ext:acme", "diff:Acme.swift#L1",
    ] {
      #expect(throws: TaskError.self) { _ = try service.link("AC-1", target: invalid) }
    }
    #expect(throws: TaskError.invalid("External parties belong to task block.")) {
      _ = try service.link("AC-1", target: "ext:acme")
    }
    #expect(
      throws: TaskError.invalid(
        "Diff references need a review subject; CLI review subjects are unavailable.")
    ) {
      _ = try service.link("AC-1", target: "diff:Acme.swift#L1")
    }
    for relation in ["blocked_by", "unknown"] {
      #expect(throws: TaskError.self) {
        _ = try service.link("AC-1", target: "AC-2", relation: relation)
      }
    }
  }

  @Test func promotionValidatesTrackerAndRefusesEveryWriter() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      for invalid in [
        "ado:0", "ado:01", "ado:bad", "gh:acme#2", "jira:key-2", "url:https://example.com",
      ] {
        #expect(throws: TaskError.self) { _ = try service.promote("AC-1", external: invalid) }
      }
      let agent = TaskService(environment: service.environment)
      #expect(throws: ActorError.self) { _ = try agent.promote("AC-1", external: "ado:42") }
      _ = try service.promote("AC-1", external: "gh:acme/platform#42")
      let task = try service.show("AC-1")
      #expect(task.status == "doing")
      #expect(task.externalRef == "gh:acme/platform#42")
      #expect(task.claimedBy == nil && task.claimedAt == nil)
      let before = try TaskOrganizationTests.counts(service)
      let failure = TaskError.promoted("AC-1", external: "gh:acme/platform#42")
      await #expect(throws: failure) {
        _ = try await service.start("AC-1", steal: true, directory: home)
      }
      var force = TaskCommit()
      force.force = true
      await #expect(throws: failure) {
        _ = try await service.close("AC-1", result: "Acme", commit: force, directory: home)
      }
      await #expect(throws: failure) {
        _ = try await service.close("AC-1", result: "Acme", dropped: true, directory: home)
      }
      #expect(throws: failure) { _ = try service.submit("AC-1") }
      #expect(throws: failure) { _ = try service.plan("AC-1", text: "Acme") }
      #expect(throws: failure) { _ = try service.tick("AC-1", step: 1, done: true) }
      #expect(throws: failure) { _ = try service.edit("AC-1") { $0 } }
      #expect(throws: failure) { _ = try service.link("AC-1", target: "url:https://example.com") }
      #expect(throws: failure) { _ = try service.archive("AC-1") }
      #expect(throws: failure) { _ = try service.archive("AC-1", keep: true) }
      #expect(throws: failure) { _ = try service.promote("AC-1", external: "ado:43") }
      #expect(try TaskOrganizationTests.counts(service) == before)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      _ = try service.link("AC-2", target: "AC-1")
      #expect(try service.show("AC-2").links.map(\.target) == ["task:AC-1"])
    }
  }
}
