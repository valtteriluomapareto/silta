import Foundation

/// Document graph validation before any restore mutation.
struct RestoreDocumentGraph {
  let tree: ExportSnapshot
  let documents: ExportDocumentSnapshot
  let slug: String

  func invalid(_ reason: String) -> ExportError {
    .invalidTree(reason: reason, workspace: slug)
  }

  func run() throws {
    let base = RestoreValidation(tree: tree, slug: slug)
    var uids = try base.rows()
    for document in documents.documents {
      try add(
        document.row, table: "doc",
        required: ExportFormat.docKeys.filter {
          !["owner", "current_rev", "verified_at"].contains($0)
        }, uids: &uids)
      for record in document.records {
        let table = record.value("table") ?? ""
        let required = Self.required[table] ?? []
        guard !required.isEmpty else { throw invalid("a document has an unknown record table") }
        try add(record, table: table, required: required, uids: &uids)
      }
    }
    try base.links(uids, tables: ExportLinks.tables)
    try links()
    for document in documents.documents { try validate(document, tasks: uids["task"] ?? []) }
    for task in tree.tasks {
      try threads(task.records.filter { $0.value("table") == "comment" })
    }
    try documents.validateCounters(workspace: slug)
  }

  private static let required = [
    "doc_rev": ["uid", "rev", "body_md", "state", "actor", "created_at"],
    "doc_verification": ["uid", "doc_rev", "actor", "app_shas", "created_at"],
    "comment": [
      "uid", "doc_rev", "seq", "kind", "body_md", "mentions", "accepted", "actor", "created_at",
    ],
  ]

  private func add(
    _ row: ExportRow, table: String, required: [String], uids: inout [String: Set<String>]
  ) throws {
    guard required.allSatisfy({ row.value($0) != nil }), let uid = row.value("uid"), !uid.isEmpty
    else {
      throw invalid("\(table) is missing required metadata or its UID")
    }
    guard uids[table, default: []].insert(uid).inserted else {
      throw invalid("\(table) uid \(uid) appears twice")
    }
  }

  private func validate(_ document: ExportDocument, tasks: Set<String>) throws {
    guard ["0", "1"].contains(document.row.value("archived") ?? "") else {
      throw invalid("a document archived flag is not 0 or 1")
    }
    try stringArray(document.row.value("previous_slugs"))
    let revisions = document.records.filter { $0.value("table") == "doc_rev" }
    var numbers: [Int64: ExportRow] = [:]
    for revision in revisions {
      let number = try ExportDocumentSnapshot.positive(revision.value("rev"), workspace: slug)
      guard numbers.updateValue(revision, forKey: number) == nil else {
        throw invalid("\(document.slug) repeats a revision number")
      }
    }
    for revision in revisions {
      try validate(revision, of: document, numbers: numbers, tasks: tasks)
    }
    let owned = Set(revisions.compactMap { $0.value("uid") })
    for record in document.records where record.value("table") != "doc_rev" {
      guard let owner = record.value("doc_rev"), owned.contains(owner) else {
        throw invalid("a document record names a revision outside its document")
      }
      if record.value("table") == "doc_verification" {
        try evidence(record.value("app_shas") ?? "")
      } else {
        _ = try ExportDocumentSnapshot.positive(record.value("seq"), workspace: slug)
        guard ["0", "1"].contains(record.value("accepted") ?? "") else {
          throw invalid("a comment accepted flag is not 0 or 1")
        }
        try stringArray(record.value("mentions"))
      }
    }
    try threads(document.records.filter { $0.value("table") == "comment" })
    try current(document, revisions: numbers)
  }

  private func validate(
    _ revision: ExportRow, of document: ExportDocument, numbers: [Int64: ExportRow],
    tasks: Set<String>
  ) throws {
    let number = try ExportDocumentSnapshot.positive(revision.value("rev"), workspace: slug)
    guard
      ["proposed", "accepted", "rejected", "superseded"].contains(revision.value("state") ?? "")
    else {
      throw invalid("a document revision has an unknown state")
    }
    if let base = revision.value("base_rev") {
      let earlier = try ExportDocumentSnapshot.positive(base, workspace: slug)
      guard earlier < number, numbers[earlier] != nil else {
        throw invalid("a document revision has no earlier owned base")
      }
    }
    if let source = revision.value("source_task"), !tasks.contains(source) {
      throw invalid("a document revision names a source task outside the workspace")
    }
    guard (revision.value("triaged_at") == nil) == (revision.value("triaged_by") == nil) else {
      throw invalid("doc:\(document.slug)@\(number) has only one triage audit field")
    }
    try stringArray(revision.value("about_refs"))
  }

  private func current(_ document: ExportDocument, revisions: [Int64: ExportRow]) throws {
    let about = tree.links.filter {
      $0.value("from_kind") == "doc" && $0.value("from") == document.row.value("uid")
        && $0.value("rel") == "about"
    }
    guard let value = document.row.value("current_rev") else {
      guard !revisions.values.contains(where: { $0.value("state") == "accepted" }), about.isEmpty
      else {
        throw invalid(
          "a document has accepted history or live attachments without a current revision")
      }
      return
    }
    let number = try ExportDocumentSnapshot.positive(value, workspace: slug)
    guard revisions[number]?.value("state") == "accepted" else {
      throw invalid("a document current revision is not an owned accepted revision")
    }
    guard document.row.value("archived") == "1" || !about.isEmpty else {
      throw invalid("a current unarchived document has no live about target")
    }
  }

  private func threads(_ comments: [ExportRow]) throws {
    let indexed = Dictionary(comments.map { ($0.value("uid") ?? "", $0) }) { first, _ in first }
    var sequences: Set<[String]> = []
    for comment in comments {
      guard sequences.insert([comment.value("doc_rev") ?? "", comment.value("seq") ?? ""]).inserted
      else {
        throw invalid("comment sequence numbers repeat under one owner")
      }
      var seen: Set<String> = []
      var next = comment.value("uid")
      while let uid = next {
        guard seen.insert(uid).inserted, let current = indexed[uid],
          current.value("doc_rev") == comment.value("doc_rev")
        else { throw invalid("a comment thread is cyclic or belongs to another owner") }
        next = current.value("thread")
      }
    }
  }

  private func stringArray(_ text: String?) throws {
    guard let text else { return }
    let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8))  // refused below
    guard parsed is [String] else {
      throw invalid("historical array metadata is not an array of strings")
    }
  }

  private func evidence(_ text: String) throws {
    guard
      let snapshots = try? JSONDecoder().decode(  // refused below
        [DocVerification.Snapshot].self, from: Data(text.utf8)),
      snapshots.allSatisfy({ [40, 64].contains($0.sha.count) && $0.sha.allSatisfy(\.isHexDigit) })
    else { throw invalid("verification evidence is not an app/ref/SHA array") }
  }
}
