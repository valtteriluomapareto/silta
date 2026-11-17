#if DEBUG
  package import Foundation
  import GRDB

  /// Synthetic document history shared by the native fixture and read acceptance.
  package enum DebugDocumentFixture {
    package static func insert(in tx: StorageTransaction, ids: any IDGenerator, at: Date) throws {
      let seed = Seed(
        tx: tx, ids: ids, at: at,
        workspace: try TaskService.workspaceID("acme", in: tx.database))
      try seed.contracts()
      try seed.references()
      try seed.discussion()
    }

    private struct Seed {
      let tx: StorageTransaction
      let ids: any IDGenerator
      let at: Date
      let workspace: Int64
      let edge = "edge:acme-mobile/acme-backend/http-api"
      var store: DocStore {
        DocStore(
          workspace: workspace, transaction: tx, actor: .human(name: "acme"), ids: ids, at: at)
      }
      func draft(
        _ slug: String, _ title: String, _ body: String, about: String = "app:acme-backend"
      ) -> DocDraft {
        var value = DocDraft(slug: slug, body: body)
        value.title = title
        value.kind = "reference"
        value.about = [about]
        value.message = "Recorded the Acme contract."
        return value
      }
      func accept(_ value: DocDraft) throws {
        let metadata = try DocMetadata.resolve(value, workspace: workspace, in: tx.database)
        let binding = try DocVerification.binding(metadata, workspace: workspace, in: tx.database)
        _ = try store.accept(value, verification: DocVerification(binding: binding, snapshots: []))
      }

      func contracts() throws {
        let old = draft(
          "order-contract", "Order contract", "# Order contract\n\nOrders use whole cents.\n",
          about: edge)
        try accept(old)
        let current = draft(
          "order-contract", "Order contract",
          """
          # Order contract

          The Acme API accepts orders from mobile and web.

          ## Amounts

          Use whole cents and an explicit currency.

          | Field | Type | Meaning |
          | --- | --- | --- |
          | total_cents | integer | Order total in whole cents |
          | currency | string | ISO currency code |

          ```json
          {"total_cents": 1299, "currency": "EUR"}
          ```

          """,
          about: edge)
        try accept(current)
        var proposed = current
        proposed.body += "\nRetry order submissions with an idempotency key.\n"
        let metadata = try DocMetadata.resolve(proposed, workspace: workspace, in: tx.database)
        _ = try DocStore(
          workspace: workspace, transaction: tx, actor: .agent(tool: "codex", session: "fixture"),
          ids: ids, at: at
        )
        .propose(
          proposed, metadata: metadata, base: 2,
          source: try TaskService.lookup("AC-9", workspace: "acme", in: tx.database).id)
        let push = draft(
          "push-categories", "Push categories",
          "# Push categories\n\nShow unknown categories under **Other**.\n", about: edge)
        _ = try DocStore(
          workspace: workspace, transaction: tx, actor: .agent(tool: "claude", session: "fixture"),
          ids: ids, at: at
        )
        .propose(
          push, metadata: DocMetadata.resolve(push, workspace: workspace, in: tx.database),
          base: nil,
          source: try TaskService.lookup("AC-12", workspace: "acme", in: tx.database).id)
      }
      func references() throws {
        try accept(
          draft(
            "auth-tokens", "Auth tokens",
            "# Auth tokens\n\nRefresh credentials before retrying an authenticated request.\n",
            about: edge))
        try accept(
          draft(
            "operations", "Operations",
            "# Operations\n\n" + (1...500).map { "Operational step \($0).\n" }.joined()))
        try accept(
          draft(
            "legacy-notes", "Legacy notes", "Historical Acme notes with metadata not recorded.\n",
            about: "app:acme-web"))
        try tx.database.execute(
          sql:
            """
            UPDATE doc_rev SET title=NULL,kind=NULL,about_refs=NULL
            WHERE doc_id=(SELECT id FROM doc WHERE workspace_id=? AND slug='legacy-notes')
            """,
          arguments: [workspace])
        try accept(
          draft("retired-endpoint", "Retired endpoint", "Archived Acme endpoint documentation.\n"))
        _ = try store.archive("retired-endpoint")
      }
      func discussion() throws {
        try tx.database.execute(
          sql: """
            INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
            SELECT ?,doc_rev.id,1,'comment','Confirmed the Acme amounts and retry contract.',
              'human:acme',? FROM doc JOIN doc_rev ON doc_rev.doc_id=doc.id
            WHERE doc.workspace_id=? AND doc.slug='order-contract' AND doc_rev.rev=2
            """, arguments: [try ids.next(at: at), utcTimestamp(at), workspace])
        try tx.recordChange(kind: "comment", rowID: tx.database.lastInsertedRowID)
      }
    }
  }
#endif
