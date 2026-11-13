import Foundation

/// One document's metadata, immutable revisions and attributed records.
struct ExportDocument: Equatable, Sendable {
  var slug: String
  var row: ExportRow
  var records: [ExportRow]

  func files() throws -> [String: Data] {
    guard WorkspaceConfig.isValidIdentifier(slug), row.value("slug") == slug else {
      throw ExportTree.invalid("the document file name and slug must be the same identifier")
    }
    let revisions = records.filter { $0.value("table") == "doc_rev" }
    let fence = TaskEditDocument.fence(for: revisions.compactMap { $0.value("body_md") })
    var markdown = "---\n"
    for field in row.fields {
      markdown += field.key + ": " + ExportFormat.quote(field.value) + "\n"
    }
    markdown += "---\n"
    for revision in revisions {
      guard let number = revision.value("rev"), let body = revision.value("body_md") else {
        throw ExportTree.invalid("a document revision has no number or body")
      }
      markdown += "## Revision \(number)\n\(fence)\n\(body)\n\(fence)\n"
    }
    let metadata = records.map { record in
      record.value("table") == "doc_rev"
        ? record.replacing("body_md", with: nil, keys: record.fields.map(\.key)) : record
    }
    return [
      "docs/\(slug).md": Data(markdown.utf8),
      "docs/\(slug).jsonl": Data(ExportFormat.jsonl(metadata).utf8),
    ]
  }
}
