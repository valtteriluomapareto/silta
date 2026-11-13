import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension BriefCommandTests {
  @Test func docViewsFollowExplicitCompactModeAndShareBoundedJSONText() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO doc(uid,workspace_id,slug,title,kind,current_rev,created_at,updated_at)
            VALUES('brief-doc',1,'read-first','Pwd=legacy-title','reference',1,'','');
            INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
            SELECT 'brief-rev',id,1,'# Heading

            Use the fallback.
            Another paragraph.','accepted','human:acme','' FROM doc WHERE slug='read-first';
            INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
              created_by,created_at)
            SELECT 'brief-link',1,'doc',doc.id,'about','app',app.id,'human:acme',''
            FROM doc JOIN app ON app.slug='api' WHERE doc.slug='read-first';
            """)
      }
      var views = ""
      for (name, mode) in [("full", [String]()), ("short", ["--short"]), ("hook", ["--hook"])] {
        let flags = ["--app", "api", "--task", "AC-2", "--budget", "10000"] + mode
        let text = try run(flags, repo, scratch)
        #expect(text.termination == .exit(0))
        let data = try fixture.data(run(flags + ["--json"], repo, scratch))
        let sections = try #require(data["sections"] as? [[String: String]])
        let docs = sections.filter { $0["id"] == "docs" }.compactMap { $0["text"] }.joined()
        #expect(!docs.isEmpty && text.stdout.contains(docs))
        #expect(!text.stdout.contains("legacy-title") && !text.stdout.contains("Another paragraph"))
        if !mode.isEmpty {
          #expect(!text.stdout.contains("Use the fallback."))
          #expect(text.stdout.contains("more: silta --ws 'acme' brief --task AC-2 --app 'api'"))
        }
        views += "## " + name + "\n" + docs
      }
      Golden.forTests().check(views, "brief-doc-views.txt")
    }
  }
}
