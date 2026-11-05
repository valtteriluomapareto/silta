package import Foundation

/// What a restore is asked to do.
package struct RestoreRequest: Sendable {
  /// The export tree.
  package var directory: URL
  /// The `--ws` the caller named, if any; it must be the tree's workspace.
  package var workspace: String?
  /// The human's go-ahead for an agent, recorded with the restore.
  package var approval: HumanApproval?
  /// Roll the transaction back and only report.
  package var dryRun: Bool

  /// A restore of `directory`.
  package init(directory: URL, workspace: String?, approval: HumanApproval?, dryRun: Bool) {
    self.directory = directory
    self.workspace = workspace
    self.approval = approval
    self.dryRun = dryRun
  }
}

/// Replaces one workspace from an export tree (spec §15).
package enum RestoreService {
  /// Restores the tree in `request.directory`, the `<root>/<workspace>` that holds
  /// `manifest.json`.
  /// The tree is read and validated before the write; the replace, its self-check and
  /// `approval`'s row then happen in one transaction, rolled back for `dryRun`. A real
  /// run that replaces a workspace first takes a before-restore snapshot. `expected` is the `--ws` the caller
  /// named, if any. Throws `ExportError` or `StorageError`; on failure the database is
  /// as it was.
  package static func restore(
    _ request: RestoreRequest, store: DatabaseStore, home: URL,
    identity: (ids: any IDGenerator, date: Date)
  ) throws -> RestoreReport {
    let (expected, approval, dryRun) = (request.workspace, request.approval, request.dryRun)
    let directory = request.directory.standardizedFileURL
    let files = try readTree(directory)
    let tree = try ExportTree.parse(files)
    let slug = tree.workspace.value("slug") ?? ""
    if let expected, expected != slug {
      throw ExportError.otherWorkspace(tree: slug, given: expected, directory: directory.path)
    }
    try RestoreValidation(tree: tree, slug: slug).run()
    let digest = ExportFormat.sha256(files[ExportFormat.manifestFile] ?? Data())
    try store.initialize()
    let milliseconds = Int64(identity.date.timeIntervalSince1970 * 1000)
    let snapshot = "silta-\(utcDay(identity.date))-before-restore-\(milliseconds).db"
    return try store.write(rollingBack: dryRun) { tx in
      var writer = RestoreWriter(tx: tx, tree: tree, slug: slug)
      var report = try writer.prepare(digest: digest, dryRun: dryRun)
      if !dryRun && !report.created {
        // Reused on a retried transaction, which has committed nothing.
        report.snapshot = try StorageBackup(home: home).snapshot(
          name: snapshot, reuseExisting: true, staging: "restore.pending"
        ).path
      }
      try writer.replace()
      try writer.check()
      report.approvalsAdded = writer.approvalsAdded
      report.reposWithoutPath = writer.reposWithoutPath
      try approval?.record(
        command: "silta restore manifest:\(digest.prefix(12))", workspace: slug,
        identity: identity, in: tx)
      return report
    }
  }

  /// Every regular file under `directory`, by relative path; `.DS_Store` is skipped.
  static func readTree(_ directory: URL) throws -> [String: Data] {
    let fm = FileManager.default
    let path = directory.path
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
      throw ExportError.notATree(path: path, reason: "no such directory", child: nil)
    }
    guard isDirectory.boolValue else {
      throw ExportError.notATree(
        path: path, reason: "it is a file; a .db backup is not restore input", child: nil)
    }
    guard fm.fileExists(atPath: directory.appending(path: ExportFormat.manifestFile).path) else {
      let child = (try? fm.contentsOfDirectory(atPath: path))?.sorted().first {  // none: no hint
        fm.fileExists(atPath: directory.appending(path: "\($0)/\(ExportFormat.manifestFile)").path)
      }
      throw ExportError.notATree(path: path, reason: "it has no manifest.json", child: child)
    }
    var files: [String: Data] = [:]
    guard let enumerator = fm.enumerator(atPath: path) else {
      throw ExportError.notATree(path: path, reason: "it can't be read", child: nil)
    }
    for case let relative as String in enumerator {
      let type = enumerator.fileAttributes?[.type] as? FileAttributeType
      if type == .typeDirectory || URL(filePath: relative).lastPathComponent == ".DS_Store" {
        continue
      }
      guard type == .typeRegular else {
        throw ExportError.notATree(
          path: path, reason: "\(relative) is a symlink or special file", child: nil)
      }
      guard let data = fm.contents(atPath: directory.appending(path: relative).path) else {
        throw ExportError.notATree(path: path, reason: "\(relative) can't be read", child: nil)
      }
      files[relative] = data
    }
    return files
  }
}

/// What the form check leaves to restore: integer values, settings as `ws edit` would
/// accept them, unique uids, references that resolve inside the tree, and no parent
/// cycles. Runs before the write, so a refusal here writes nothing at all.
private struct RestoreValidation {
  let tree: ExportSnapshot
  let slug: String

  func run() throws {
    try settings()
    var uids: [String: Set<String>] = [:]
    func add(_ table: String, _ row: ExportRow) throws {
      try integers(row, in: table)
      guard let uid = row.value("uid") else { return }
      guard uids[table, default: []].insert(uid).inserted else {
        throw ExportError.invalidTree("\(table) uid \(uid) appears twice")
      }
    }
    try integers(tree.workspace, in: "workspace")
    for (section, format) in zip(tree.sections, ExportFormat.sections) {
      for row in section.rows { try add(format.table, row) }
    }
    for task in tree.tasks {
      try add("task", task.row)
      for record in task.records { try add(record.value("table") ?? "", record) }
    }
    for row in tree.links { try add("link", row) }
    for row in tree.aliasDecisions { try add("alias_decision", row) }
    for row in tree.approvals { try add("approval", row) }
    try references(uids)
    try parents()
  }

  private func settings() throws {
    let json = tree.workspace.value("settings") ?? "{}"
    let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8))  // refused below
    guard let object = parsed as? [String: Any] else {
      throw ExportError.invalidTree("settings are not a JSON object")
    }
    let known = Set(WorkspaceSettings.CodingKeys.allCases.map(\.rawValue))
    if let unknown = Set(object.keys).subtracting(known).sorted().first {
      throw ExportError.invalidTree("settings have the unknown key \(unknown)")
    }
    let settings = WorkspaceSettings(workspace: slug, json: json)
    do {
      _ = try settings.reviewGate
      _ = try settings.proposals
      _ = try settings.archiveAfterDays
      _ = try settings.staleDays
    } catch let error as WorkspaceError {
      throw ExportError.invalidTree("settings: \(error.message)")
    }
  }

  private func integers(_ row: ExportRow, in table: String) throws {
    for field in row.fields where ExportFormat.integerKeys.contains(field.key) {
      guard Int64(field.value) != nil else {
        throw ExportError.invalidTree("\(table) \(field.key) \(field.value) is not an integer")
      }
    }
  }

  private func references(_ uids: [String: Set<String>]) throws {
    func resolve(_ uid: String?, _ table: String, from: String) throws {
      guard let uid, !uids[table, default: []].contains(uid) else { return }
      throw ExportError.invalidTree("\(from) names \(table) \(uid), which the tree doesn't hold")
    }
    var rows: [(String, ExportRow)] = zip(tree.sections, ExportFormat.sections).flatMap { pair in
      pair.0.rows.map { (pair.1.table, $0) }
    }
    rows += tree.tasks.map { ("task", $0.row) } + tree.aliasDecisions.map { ("alias_decision", $0) }
    for (table, row) in rows {
      for (key, reference) in ExportFormat.references[table] ?? [:] {
        try resolve(row.value(key), reference.table, from: table)
      }
    }
    for task in tree.tasks {
      let comments = Set(
        task.records.compactMap { $0.value("table") == "comment" ? $0.value("uid") : nil })
      for record in task.records {
        if let thread = record.value("thread"), !comments.contains(thread) {
          throw ExportError.invalidTree(
            "a comment of \(task.ref) threads under \(thread), not on that task")
        }
      }
    }
    let revisions = Set(
      tree.tasks.flatMap { task in
        task.records.compactMap {
          $0.value("table") == "task_plan_rev"
            ? "\(task.row.value("uid") ?? "")@\($0.value("rev") ?? "")" : nil
        }
      })
    for link in tree.links {
      guard link.value("from") != nil, (link.value("to") == nil) != (link.value("to_ext") == nil)
      else { throw ExportError.invalidTree("link \(link.value("uid") ?? "") has a missing end") }
      try resolve(
        link.value("from"), ExportFormat.linkTables[link.value("from_kind") ?? ""] ?? "",
        from: "link")
      guard let to = link.value("to") else { continue }
      if link.value("to_kind") == "task_plan_rev" {
        guard revisions.contains("\(to)@\(link.value("to_rev") ?? "")") else {
          throw ExportError.invalidTree(
            "a link names plan revision \(link.value("to_rev") ?? "") of \(to), which the tree doesn't hold"
          )
        }
      } else {
        try resolve(to, ExportFormat.linkTables[link.value("to_kind") ?? ""] ?? "", from: "link")
      }
    }
  }

  private func parents() throws {
    let parent = Dictionary(
      tree.tasks.map { ($0.row.value("uid") ?? "", $0.row.value("parent")) }
    ) { first, _ in first }
    for task in tree.tasks {
      var seen: Set<String> = []
      var next = task.row.value("uid")
      while let uid = next {
        guard seen.insert(uid).inserted else {
          throw ExportError.invalidTree("\(task.ref) is its own ancestor")
        }
        next = parent[uid] ?? nil
      }
    }
  }
}
