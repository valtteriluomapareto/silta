import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct BriefVisibilityTests {
  @Test func backlogVisibilityParity() throws {
    try withScratchDirectory { home in
      let base = try TaskServiceTests.environment(home)
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + """
          repos: [{slug: platform}]
          apps: [{slug: api, repo: platform, ref: main}]
          """, to: base.db)
      try WorkspaceSelection.use("acme", in: base.db)
      let cutoff = TaskService.timestamp(TaskServiceTests.now.addingTimeInterval(-14 * 86400))
      try seed(base.db, cutoff: cutoff)
      let location = LocationResult(
        path: "/acme", worktree: "/acme", workspace: "acme",
        repo: "platform", app: "api", branch: "main", head: "a", confidence: "high",
        reason: "single", candidates: [])
      for actor in [TaskServiceTests.agent, try TaskServiceTests.human()] {
        let env = try TaskServiceTests.environment(home, actor: actor)
        let listed = try TaskService(environment: env).list().map(\.ref)
        let sections = try env.db.read {
          try BriefBacklog(
            db: $0, location: location, actor: actor, date: TaskServiceTests.now,
            archiveDays: WorkspaceSettings.defaultArchiveAfterDays
          ).sections(topics: [])
        }
        let refs = sections.filter { ["open_tasks", "recently_done"].contains($0.id) }
          .compactMap {
            $0.text.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)
          }
        #expect(Set(refs) == Set(listed))
        #expect(refs.contains("AC-4"))
        #expect(refs.contains("AC-6"))
        #expect(!refs.contains("AC-5") && !refs.contains("AC-7") && !refs.contains("AC-8"))
      }
      try base.db.write {
        try $0.database.execute(sql: "UPDATE task SET closed_at='bad' WHERE seq=4")
      }
      #expect(throws: StorageError.self) { _ = try TaskService(environment: base).list() }
      #expect(throws: StorageError.self) {
        _ = try base.db.read {
          try BriefBacklog(
            db: $0, location: location, actor: TaskServiceTests.agent,
            date: TaskServiceTests.now, archiveDays: 14
          ).sections(topics: [])
        }
      }
    }
  }
  private func seed(_ store: DatabaseStore, cutoff: String) throws {
    try store.write { tx in
      for seq in 1...8 {
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,created_by,
              created_at,updated_at,closed_at,archive_override,external_ref)
            VALUES(?,1,?,'Acme',?,1,?,'','',?,?,?)
            """,
          arguments: [
            "task-\(seq)", seq,
            [2, 3].contains(seq) ? "proposed" : (4...7).contains(seq) ? "done" : "todo",
            seq == 2 ? "agent:codex:acme" : "agent:codex:other",
            seq == 4 ? cutoff : "2020-01-01T00:00:00.000Z",
            seq == 6 ? "kept" : seq == 7 ? "archived" : nil,
            seq == 8 ? "ado:8" : nil,
          ])
      }
    }
  }

}
