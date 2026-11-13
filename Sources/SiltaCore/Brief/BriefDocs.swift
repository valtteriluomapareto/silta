import Foundation
import GRDB

/// Reads accepted document attachments in the brief's existing workspace snapshot.
struct BriefDocs {
  let db: Database
  let workspace: String
  let workspaceID: Int64
  let topics: Set<Int64>
  let compact: Bool
  let counts: [String: Int]

  init(db: Database, location: LocationResult, topics: Set<Int64>, compact: Bool) throws {
    self.db = db
    workspace = location.workspace
    workspaceID = try TaskService.workspaceID(workspace, in: db)
    self.compact = compact
    let current = try location.currentTask.map {
      try TaskService.lookup($0.ref, workspace: location.workspace, in: db).id
    }
    let taskTopics = try Int64.fetchAll(
      db,
      sql: """
        SELECT DISTINCT t.id FROM link l JOIN topic t ON t.id=l.to_id
        WHERE l.workspace_id=? AND t.workspace_id=? AND l.from_kind='task' AND l.from_id=?
          AND l.rel='about' AND l.to_kind='topic'
        """, arguments: [workspaceID, workspaceID, current])
    self.topics = topics.union(taskTopics)
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT l.to_kind,l.to_id,count(DISTINCT d.id) AS total \(Self.accepted)
        GROUP BY l.to_kind,l.to_id
        """, arguments: ["workspace": workspaceID])
    counts = Dictionary(
      uniqueKeysWithValues: rows.map {
        (($0["to_kind"] as String) + ":\($0["to_id"] as Int64)", $0["total"] as Int)
      })
  }

  func group(kind: String, id: Int64) throws -> BriefDocGroup? {
    guard let total = counts[kind + ":\(id)"] else { return nil }
    let ref = try TaskLinkTarget(kind: kind, id: id).rendered(in: db)
    var previews: [String] = []
    if !compact {
      let topicMatch =
        topics.isEmpty
        ? "0"
        : """
        EXISTS(SELECT 1 FROM link t WHERE t.workspace_id=:workspace
          AND t.from_kind='doc' AND t.from_id=d.id AND t.rel='about' AND t.to_kind='topic'
          AND t.to_id IN (\(topics.sorted().map(String.init).joined(separator: ","))))
        """
      previews = try Row.fetchAll(
        db,
        sql: """
          SELECT d.slug,d.kind,r.body_md \(Self.accepted) AND l.to_kind=:kind AND l.to_id=:id
          GROUP BY d.id ORDER BY (\(topicMatch)) DESC,d.slug COLLATE BINARY,d.id LIMIT 2
          """, arguments: ["workspace": workspaceID, "kind": kind, "id": id]
      ).map { row in
        let summary = Self.summary(row["body_md"])
        return "  " + TaskError.shown("doc:" + (row["slug"] as String))
          + " [" + TaskError.shown(row["kind"]) + "]"
          + (summary.isEmpty ? "" : " " + summary) + "\n"
      }
    }
    return BriefDocGroup(ref: ref, workspace: workspace, total: total, rows: previews)
  }

  func topicGroups() throws -> [BriefDocGroup] {
    guard !topics.isEmpty else { return [] }
    return try Row.fetchAll(
      db,
      sql: """
        SELECT id FROM topic WHERE workspace_id=?
        AND id IN (\(topics.sorted().map(String.init).joined(separator: ","))) ORDER BY slug COLLATE BINARY,id
        """, arguments: [workspaceID]
    ).compactMap { try group(kind: "topic", id: $0["id"]) }
  }

  private static let accepted = """
    FROM doc d JOIN doc_rev r ON r.doc_id=d.id AND r.rev=d.current_rev
    JOIN link l ON l.from_kind='doc' AND l.from_id=d.id
    WHERE d.workspace_id=:workspace AND l.workspace_id=:workspace AND d.archived=0
      AND r.state='accepted' AND l.rel='about' AND l.to_id IS NOT NULL
      AND l.to_kind IN ('app','edge','service','topic')
    """

  private static func summary(_ body: String) -> String {
    let lines = SecretGuard.redacted(body).split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let first = lines.first { !$0.isEmpty && $0.firstMatch(of: /^#{1,6}(?:\s|$)/) == nil } ?? ""
    return String(TaskError.shown(first).prefix(120))
  }
}
