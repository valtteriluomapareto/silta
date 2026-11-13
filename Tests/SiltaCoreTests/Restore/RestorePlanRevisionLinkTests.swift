import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestorePlanRevisionLinkTests {
  @Test func distinctStoredPlanRevisionsHaveDistinctLinkIdentities() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO task_plan_rev(id,task_id,rev,body_md,actor,created_at) VALUES
              (1601,700,1,'First plan','human:acme',''),
              (1602,700,2,'Second plan','human:acme','');
            UPDATE task SET plan_rev=2,plan_md='Second plan' WHERE id=700;
            INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
              created_by,created_at,anchor) VALUES
              ('plan-one',17,'task',700,'cites','task_plan_rev',1601,'human:acme','','#L1'),
              ('plan-two',17,'task',700,'cites','task_plan_rev',1602,'human:acme','','#L1');
            """)
      }
      let before = try RestoreSupport.dump(store)
      var graph = try RestoreDocumentGraphFixture.graph()
      graph.tree.links = try store.read { try ExportLinks.read($0, workspace: 17) }
      graph.tree.tasks[1].records = [1, 2].map { number in
        ExportDocumentTests.row([
          ("table", "task_plan_rev"), ("rev", String(number)),
          ("body_md", number == 1 ? "First plan" : "Second plan"),
          ("actor", "human:acme"), ("created_at", ""),
        ])
      }
      graph.tree.tasks[1].row = graph.tree.tasks[1].row
        .replacing("plan_rev", with: "2", keys: ExportFormat.taskKeys)
        .replacing("plan_md", with: "Second plan", keys: ExportFormat.taskKeys)
      let links = graph.tree.links.filter { $0.value("to_kind") == "task_plan_rev" }
      #expect(
        links.compactMap { $0.value("to") }
          == Array(repeating: ExportDocumentTests.uid("010"), count: 2))
      #expect(links.compactMap { $0.value("to_rev") } == ["1", "2"])
      try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
      #expect(try RestoreSupport.dump(store) == before)
    }
  }
}
