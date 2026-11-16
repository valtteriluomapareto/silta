import Foundation

/// Document truth and standalone allocation streams, independent of physical IDs.
struct ExportDocumentSnapshot: Equatable, Sendable {
  var documents: [ExportDocument]
  var revisionAllocations: [ExportRow]
  var legacyCommentSequences: [ExportRow]?

  static func parse(_ files: [String: Data], workspace: String, targets: Bool = true) throws -> Self
  {
    let reader = ExportFileReader(files: files, slug: workspace)
    let names = files.keys.filter { $0.hasPrefix("docs/") && $0.hasSuffix(".md") }
      .map { String($0.dropFirst("docs/".count).dropLast(".md".count)) }
      .sorted(by: ExportSnapshot.byteOrder)
    let documents = try names.map { name in
      let paths = ["docs/\(name).md", "docs/\(name).jsonl"]
      let pair = files.filter { paths.contains($0.key) }
      return try ExportTree.parseDocument(pair, slug: name, workspace: workspace, targets: targets)
    }
    let snapshot = Self(
      documents: documents,
      revisionAllocations: try reader.jsonl(
        ExportFormat.docAllocationsFile, keys: ["slug", "next"]),
      legacyCommentSequences: files[ExportFormat.docCommentSequencesFile] == nil
        ? nil
        : try reader.jsonl(ExportFormat.docCommentSequencesFile, keys: ["doc_rev", "next"]))
    if snapshot.legacyCommentSequences?.contains(where: {
      $0.value("doc_rev") == nil || $0.value("next") == nil
    }) == true {
      throw reader.invalid("doc_comment_sequences.jsonl rows require doc_rev and next")
    }
    try snapshot.validateCounters(workspace: workspace)
    guard try snapshot.files() == files else {
      throw reader.invalid("document files or allocation streams are not in the form export writes")
    }
    return snapshot
  }

  func files() throws -> [String: Data] {
    func stream(_ rows: [ExportRow], key: String) -> Data {
      let sorted = rows.sorted {
        ExportSnapshot.byteOrder($0.value(key) ?? "", $1.value(key) ?? "")
      }
      return Data(ExportFormat.jsonl(sorted).utf8)
    }
    var files = [ExportFormat.docAllocationsFile: stream(revisionAllocations, key: "slug")]
    if let legacyCommentSequences {
      files[ExportFormat.docCommentSequencesFile] = stream(legacyCommentSequences, key: "doc_rev")
    }
    for document in documents {
      for (path, data) in try document.files() {
        guard files.updateValue(data, forKey: path) == nil else {
          throw ExportTree.invalid("document file names must be unique")
        }
      }
    }
    return files
  }
}
