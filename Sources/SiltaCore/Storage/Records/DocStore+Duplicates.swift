import Foundation
import GRDB

extension DocStore {
  func targetIdentities(_ targets: [TaskLinkTarget]) throws -> [DocTargetIdentity] {
    try targets.map { target in
      guard let id = target.id,
        let uid = try StoredUID.fetch(
          db, sql: "SELECT uid FROM \(target.kind) WHERE id=?", arguments: [id])
      else { throw StorageError.corrupt }
      return DocTargetIdentity(kind: target.kind, uid: uid)
    }
  }

  func refuseDuplicate(
    _ draft: DocDraft, metadata: DocMetadata, base: Int?,
    targets: [DocTargetIdentity], old: Row?
  ) throws {
    guard let old else { return }
    let document: Int64 = old["id"]
    let expectedTitle = Data(metadata.title.utf8)
    let expectedKind = Data(metadata.kind.utf8)
    let expectedTargets = Set(targets)
    let cursor = try Row.fetchCursor(
      db,
      sql: """
        SELECT rev,state,CAST(title AS BLOB) AS title,CAST(kind AS BLOB) AS kind,
          CAST(about_targets AS BLOB) AS targets FROM doc_rev
        WHERE doc_id=? AND CAST(body_md AS BLOB)=?
          AND ((state='accepted' AND rev=?) OR (state='proposed' AND base_rev IS ?))
        ORDER BY CASE WHEN state='accepted' THEN 0 ELSE 1 END,rev
        """, arguments: [document, Data(draft.body.utf8), base, base])
    defer { withExtendedLifetime(cursor) {} }
    while let row = try cursor.next() {
      var title: Data? = row["title"]
      var kind: Data? = row["kind"]
      if let title, title != expectedTitle { continue }
      if let kind, kind != expectedKind { continue }
      var saved = try Self.decodedTargets(row["targets"])
      if title == nil || kind == nil || saved == nil {
        guard row["state"] as String == "accepted",
          row["rev"] as Int? == old["current_rev"] as Int?
        else { continue }
        let current = try currentMetadata(document)
        title = title ?? (current.fields["title"] as Data)
        kind = kind ?? (current.fields["kind"] as Data)
        saved = saved ?? current.targets
      }
      if title == expectedTitle, kind == expectedKind, saved.map(Set.init) == expectedTargets {
        throw DocError.duplicate("doc:\(draft.slug)@\(row["rev"] as Int)")
      }
    }
  }

  private func currentMetadata(_ document: Int64) throws
    -> (fields: Row, targets: [DocTargetIdentity])
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT CAST(title AS BLOB) AS title,CAST(kind AS BLOB) AS kind FROM doc WHERE id=?",
        arguments: [document])
    else { throw StorageError.corrupt }
    let links = try Self.attachments(document, workspace: workspace, in: db).map { link in
      let kind: String = link["to_kind"]
      guard ["app", "edge", "service", "topic"].contains(kind),
        let id: Int64 = link["to_id"], link["to_ext"] as String? == nil,
        link["anchor"] as String? == nil
      else { throw StorageError.corrupt }
      return TaskLinkTarget(kind: kind, id: id)
    }
    return try (row, targetIdentities(links))
  }

  private static func decodedTargets(_ bytes: Data?) throws -> [DocTargetIdentity]? {
    guard let bytes else { return nil }
    do {
      let targets = try JSONDecoder().decode([DocTargetIdentity].self, from: bytes)
      guard !targets.isEmpty, Set(targets).count == targets.count,
        targets.allSatisfy({ StoredUID.valid(Data($0.uid.utf8)) })
      else { throw StorageError.corrupt }
      return targets
    } catch { throw StorageError.corrupt }
  }
}
