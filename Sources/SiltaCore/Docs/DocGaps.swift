import Foundation
import GRDB

/// Map items next to an app that no current workspace doc covers. Advisory only: the
/// result feeds hints and never refuses or changes a write.
enum DocGaps {
  /// Current accepted, nonarchived attachments of workspace docs; binds `:workspace`.
  static let acceptedAttachments = """
    FROM doc d JOIN doc_rev r ON r.doc_id=d.id AND r.rev=d.current_rev
    JOIN link l ON l.from_kind='doc' AND l.from_id=d.id
    WHERE d.workspace_id=:workspace AND l.workspace_id=:workspace AND d.archived=0
      AND r.state='accepted' AND l.rel='about' AND l.to_id IS NOT NULL
      AND l.to_kind IN ('app','edge','service','topic')
    """

  /// Whether this store records proposal target snapshots; reads never migrate, so a
  /// store from before them has no pending cover.
  static func snapshots(in db: Database) throws -> Bool {
    try db.columns(in: "doc_rev").contains { $0.name == "about_targets" }
  }

  /// Whether a pending proposal names the item whose uid is the SQL expression `uid`.
  /// Only an array snapshot's object elements count; anything else is no cover and never
  /// an error. Binds `:workspace`.
  static func pending(kind: String, uid: String, snapshots: Bool) -> String {
    guard snapshots else { return "0" }
    return """
      EXISTS(SELECT 1 FROM doc d JOIN doc_rev r ON r.doc_id=d.id
        WHERE d.workspace_id=:workspace AND d.archived=0 AND r.state='proposed'
          AND EXISTS(SELECT 1 FROM json_each(CASE WHEN json_valid(r.about_targets) THEN
              CASE json_type(r.about_targets) WHEN 'array' THEN r.about_targets END END)
            WHERE CASE WHEN type='object' THEN
              json_extract(value,'$.kind')='\(kind)' AND json_extract(value,'$.uid')=\(uid)
              ELSE 0 END))
      """
  }

  /// Whether an accepted doc or a pending proposal covers one app or edge.
  static func covered(
    kind: String, id: Int64, workspaceID: Int64, snapshots: Bool, in db: Database
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 \(acceptedAttachments) AND l.to_kind=x.kind AND l.to_id=:id)
          OR \(pending(kind: kind, uid: "x.uid", snapshots: snapshots))
        FROM (SELECT '\(kind)' AS kind,uid FROM \(kind) WHERE id=:id) x
        """, arguments: ["workspace": workspaceID, "id": id]) ?? false
  }

  /// Edges between the app and a different app that no doc covers, in the order the
  /// brief lists neighbours.
  static func appEdges(appID: Int64, workspaceID: Int64, in db: Database) throws -> [String] {
    let pending = pending(kind: "edge", uid: "edge.uid", snapshots: try snapshots(in: db))
    return try Int64.fetchAll(
      db,
      sql: """
        SELECT edge.id FROM edge
        JOIN app source ON source.id=edge.from_app_id
        JOIN app target ON target.id=edge.to_app_id
        WHERE (edge.from_app_id=:app OR edge.to_app_id=:app)
          AND edge.from_app_id<>edge.to_app_id
          AND NOT EXISTS(SELECT 1 \(acceptedAttachments) AND l.to_kind='edge' AND l.to_id=edge.id)
          AND NOT \(pending)
        ORDER BY source.slug,target.slug,edge.kind,edge.id
        """, arguments: ["app": appID, "workspace": workspaceID]
    ).map { try TaskLinkTarget(kind: "edge", id: $0).rendered(in: db) }
  }

  /// One warning naming at most two gaps, or none when every edge is covered. It ends
  /// with a `doc propose` command unless the workspace or the first ref would leak.
  static func warning(_ edges: [String], workspace: String, task: String) -> OutputWarning? {
    guard let first = edges.first else { return nil }
    let named = edges.prefix(2).map(DocService.shown)
    let more = edges.count > 2 ? " and \(edges.count - 2) more" : ""
    let list = named.joined(separator: named.count == 2 && more.isEmpty ? " and " : ", ") + more
    let safe = SecretGuard.matches(in: workspace).isEmpty && DocService.safeReference(first)
    let propose =
      safe
      ? ": silta --ws " + shellWord(workspace) + " doc propose <slug> --title <title> --about "
        + shellWord(first) + " --task " + shellWord(task) + " -m <why> -F -"
      : " with --task " + task
    return OutputWarning(
      code: "doc_gap",
      message:
        "No doc or pending proposal covers \(list). If this work taught something an agent "
        + "in the other app would need, tell the human or propose one" + propose
        + "; otherwise ignore this.")
  }
}

extension DocService {
  /// A map ref as output shows it: masked, and decoded only when it holds no secret.
  static func shown(_ ref: String) -> String {
    TaskError.shown(safeReference(ref) ? ref : ref.removingPercentEncoding ?? ref)
  }

  /// The scoped `doc ls` recovery for `about`, unfiltered or unscoped when either would leak.
  static func listCommand(workspace: String, about ref: String) -> String {
    guard SecretGuard.matches(in: workspace).isEmpty else { return "silta ws ls" }
    return "silta --ws " + shellWord(workspace) + " doc ls"
      + (safeReference(ref) ? " --about " + shellWord(ref) : "")
  }
}
