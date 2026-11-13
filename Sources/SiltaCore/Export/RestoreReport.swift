import Foundation

/// What a restore did, or would do, to the workspace: enough for the human to approve it
/// knowingly from a dry run (spec §15).
package struct RestoreReport: Encodable, Equatable, Sendable {
  /// Row counts before and after.
  package struct Counts: Encodable, Equatable, Sendable {
    /// Before the restore.
    package var before: Int
    /// After the restore.
    package var after: Int

    /// The two counts.
    package init(before: Int, after: Int) {
      self.before = before
      self.after = after
    }
  }

  /// A setting whose stored JSON value differs; nil when the key is unset.
  package struct SettingChange: Encodable, Equatable, Sendable {
    /// The setting key.
    package var key: String
    /// The current value as JSON.
    package var before: String?
    /// The tree's value as JSON.
    package var after: String?

    /// One changed setting.
    package init(key: String, before: String?, after: String?) {
      self.key = key
      self.before = before
      self.after = after
    }
  }

  /// A table outside the tasks whose row count changes.
  package struct RowCount: Encodable, Equatable, Sendable {
    /// The table.
    package var table: String
    /// Rows before the restore.
    package var before: Int
    /// Rows after the restore.
    package var after: Int
  }

  /// The ref the next task gets, before and after: the counter never rewinds, so a
  /// restore of an older or a moved tree can move it. Nil when there is no counter.
  package struct TaskRef: Encodable, Equatable, Sendable {
    /// The ref a task added now would get.
    package var before: String?
    /// The ref a task added after the restore would get.
    package var after: String?

    /// The two refs.
    package init(before: String?, after: String?) {
      self.before = before
      self.after = after
    }
  }

  /// A live claim the restore replaces.
  package struct Claim: Encodable, Equatable, Sendable {
    /// The task ref as it is now.
    package var task: String
    /// The claiming actor.
    package var actor: String

    /// One replaced claim.
    package init(task: String, actor: String) {
      self.task = task
      self.actor = actor
    }
  }

  /// The workspace slug.
  package var workspace: String
  /// Whether the transaction was rolled back.
  package var dryRun: Bool
  /// Whether the workspace did not exist before.
  package var created: Bool
  /// Whether the replaced workspace has the tree's uid; true when created.
  package var sameUID: Bool
  /// The sha256 of the tree's `manifest.json`.
  package var manifestSHA256: String
  /// Tasks before and after.
  package var tasks: Counts
  /// Documents before and after.
  package var docs: Counts
  /// Current document refs absent from the incoming stable identities.
  package var removedDocs: [String]
  /// Incoming refs of retained documents whose literal content differs.
  package var changedDocs: [String]
  /// A presentation value with safe document and workspace identities.
  package var presented: Self {
    var report = self
    report.workspace = SecretGuard.redacted(workspace)
    report.snapshot = snapshot.map(SecretGuard.redacted)
    report.removedDocs = removedDocs.map(SecretGuard.redacted)
    report.changedDocs = changedDocs.map(SecretGuard.redacted)
    return report
  }
  /// Refs of tasks that exist now and not in the tree.
  package var removed: [String]
  /// Refs of tasks whose row or records differ from the tree.
  package var changed: [String]
  /// Tables outside the tasks whose row counts change.
  package var rows: [RowCount]
  /// Settings whose values differ.
  package var settings: [SettingChange]
  /// The task ref the next task gets, before and after.
  package var nextTaskRef: TaskRef
  /// Approval rows the tree adds.
  package var approvalsAdded: Int
  /// Claims that change or disappear.
  package var claimsReplaced: [Claim]
  /// Repo slugs left without a local path.
  package var reposWithoutPath: [String]
  /// The before-restore snapshot, for a real run.
  package var snapshot: String?

  enum CodingKeys: String, CodingKey {
    case workspace, created, tasks, removed, changed, rows, settings, snapshot
    case docs
    case removedDocs = "removed_docs"
    case changedDocs = "changed_docs"
    case dryRun = "dry_run"
    case nextTaskRef = "next_task_ref"
    case sameUID = "same_uid"
    case manifestSHA256 = "manifest_sha256"
    case approvalsAdded = "approvals_added"
    case claimsReplaced = "claims_replaced"
    case reposWithoutPath = "repos_without_path"
  }
}

extension RestoreReport {
  /// What replacing `current` (nil: no such workspace) with `tree` changes.
  static func between(
    _ current: ExportSnapshot?, _ tree: ExportSnapshot, workspace: String, digest: String,
    dryRun: Bool
  ) -> RestoreReport {
    let incoming = Dictionary(
      tree.tasks.map { (Data(($0.row.value("uid") ?? "").utf8), $0) },
      uniquingKeysWith: { first, _ in first })
    let existing = current?.tasks ?? []
    var removed: [String] = []
    var changed: [String] = []
    var claims: [Claim] = []
    for task in existing {
      let replacement = incoming[Data((task.row.value("uid") ?? "").utf8)]
      if replacement == nil {
        removed.append(task.ref)
      } else if replacement != task {
        changed.append(replacement?.ref ?? task.ref)
      }
      if let actor = task.row.value("claimed_by"), replacement?.row.value("claimed_by") != actor {
        claims.append(Claim(task: task.ref, actor: actor))
      }
    }
    let documents = documentChanges(current, tree)
    return RestoreReport(
      workspace: workspace, dryRun: dryRun, created: current == nil,
      sameUID: current.map {
        $0.workspace.value("uid").map { Data($0.utf8) }
          == tree.workspace.value("uid").map { Data($0.utf8) }
      } ?? true,
      manifestSHA256: digest, tasks: Counts(before: existing.count, after: tree.tasks.count),
      docs: Counts(
        before: current?.documents.documents.count ?? 0, after: tree.documents.documents.count),
      removedDocs: documents.removed, changedDocs: documents.changed,
      removed: removed, changed: changed, rows: rowCounts(current, tree),
      settings: settingChanges(
        current?.workspace.value("settings"), tree.workspace.value("settings")),
      nextTaskRef: taskRefs(current, tree),
      approvalsAdded: 0, claimsReplaced: claims, reposWithoutPath: [], snapshot: nil)
  }

  private static func documentChanges(_ current: ExportSnapshot?, _ tree: ExportSnapshot)
    -> (removed: [String], changed: [String])
  {
    guard let current else { return ([], []) }
    let incoming = Dictionary(
      tree.documents.documents.map { (Data(($0.row.value("uid") ?? "").utf8), $0) }
    ) { first, _ in first }
    var removed: [String] = []
    var changed: [String] = []
    for document in current.documents.documents {
      guard let replacement = incoming[Data((document.row.value("uid") ?? "").utf8)] else {
        removed.append("doc:" + document.slug)
        continue
      }
      if replacement.row != document.row || replacement.records != document.records
        || !replacement.slug.utf8.elementsEqual(document.slug.utf8)
        || documentLinks(document, in: current) != documentLinks(replacement, in: tree)
      {
        changed.append("doc:" + replacement.slug)
      }
    }
    return (
      removed.sorted(by: ExportSnapshot.byteOrder), changed.sorted(by: ExportSnapshot.byteOrder)
    )
  }

  private static func documentLinks(_ document: ExportDocument, in tree: ExportSnapshot)
    -> [ExportRow]
  {
    let uid = Data((document.row.value("uid") ?? "").utf8)
    let comments = Set(
      document.records.compactMap { row -> Data? in
        guard row.value("table") == "comment", let uid = row.value("uid") else { return nil }
        return Data(uid.utf8)
      })
    return tree.links.filter { link in
      guard let owner = link.value("from") else { return false }
      let source = Data(owner.utf8)
      return (link.value("from_kind") == "doc" && source == uid)
        || (link.value("from_kind") == "comment" && comments.contains(source))
    }
  }

  /// The task refs before and after, each with its own workspace's prefix: the counter
  /// takes the highest of what the database holds, what the tree holds and one past the
  /// tree's last task.
  private static func taskRefs(_ current: ExportSnapshot?, _ tree: ExportSnapshot) -> TaskRef {
    func ref(_ next: Int64?, prefix: String) -> String? {
      next.map { "\(prefix)-\($0)" }
    }
    let stored = current?.workspace.value("next_task_seq").flatMap { Int64($0) }
    return TaskRef(
      before: ref(stored, prefix: current?.workspace.value("task_prefix") ?? ""),
      after: ref(
        RestoreWriter.nextTaskSeq(stored: stored, tree: tree),
        prefix: tree.workspace.value("task_prefix") ?? ""))
  }

  /// Row counts of the tables outside the tasks that differ.
  private static func rowCounts(_ current: ExportSnapshot?, _ tree: ExportSnapshot) -> [RowCount] {
    func counts(_ snapshot: ExportSnapshot?) -> [(String, Int)] {
      let documents = snapshot?.documents.documents.flatMap(\.records) ?? []
      let taskComments =
        snapshot?.tasks.flatMap(\.records).filter {
          $0.value("table") == "comment"
        }.count ?? 0
      return zip(
        ExportFormat.sections,
        snapshot?.sections ?? tree.sections.map { .init(name: $0.name, rows: []) }
      )
      .map { ($0.table, $1.rows.count) }
        + [
          ("link", snapshot?.links.count ?? 0),
          ("alias_decision", snapshot?.aliasDecisions.count ?? 0),
          ("doc_rev", documents.filter { $0.value("table") == "doc_rev" }.count),
          ("doc_verification", documents.filter { $0.value("table") == "doc_verification" }.count),
          ("comment", taskComments + documents.filter { $0.value("table") == "comment" }.count),
        ]
    }
    return zip(counts(current), counts(tree)).compactMap { before, after in
      before.1 == after.1 ? nil : RowCount(table: before.0, before: before.1, after: after.1)
    }
  }

  private static func settingChanges(_ before: String?, _ after: String?) -> [SettingChange] {
    func values(_ json: String?) -> [String: String] {
      let bytes = Data((json ?? "{}").utf8)
      let parsed = try? JSONSerialization.jsonObject(with: bytes)  // not JSON: no settings
      return ((parsed as? [String: Any]) ?? [:]).compactMapValues { value in
        let data = try? JSONSerialization.data(  // unencodable: left out
          withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(bytes: $0, encoding: .utf8) }
      }
    }
    let old = values(before)
    let new = values(after)
    return Set(old.keys).union(new.keys).sorted().compactMap { key in
      old[key] == new[key] ? nil : SettingChange(key: key, before: old[key], after: new[key])
    }
  }
}
