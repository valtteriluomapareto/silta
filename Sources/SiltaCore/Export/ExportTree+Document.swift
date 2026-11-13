import Foundation

extension ExportTree {
  /// Reads an immutable document pair without interpreting historical refs or evidence.
  static func parseDocument(
    _ files: [String: Data], slug: String, workspace: String
  ) throws -> ExportDocument {
    try ExportFileReader(files: files, slug: workspace).document(slug)
  }
}

extension ExportFileReader {
  func document(_ name: String) throws -> ExportDocument {
    guard WorkspaceConfig.isValidIdentifier(name) else {
      throw invalid("the document file name is not an identifier")
    }
    let path = "docs/\(name).md"
    var lines = try lines(path)[...]
    let values = try frontmatter(&lines, in: path)
    guard values["slug"] == name else { throw invalid("\(path) names another document") }
    let bodies = try documentBodies(&lines, in: path)
    let records = try documentRecords("docs/\(name).jsonl", bodies: bodies)
    let document = ExportDocument(
      slug: name, row: ExportRow(keys: ExportFormat.docKeys, values: values), records: records)
    let rendered = try document.files()
    guard files.count == rendered.count,
      rendered.allSatisfy({ files[$0.key] == $0.value })
    else { throw invalid("docs/\(name) is not in the form export writes") }
    return document
  }

  private func documentBodies(
    _ lines: inout ArraySlice<String>, in path: String
  ) throws -> [String: String] {
    var bodies: [String: String] = [:]
    var previous: Int64 = 0
    while let heading = lines.popFirst() {
      let number = String(heading.dropFirst("## Revision ".count))
      guard heading.hasPrefix("## Revision "), let revision = Int64(number),
        String(revision) == number, revision > previous
      else { throw invalid("\(path) has an invalid or unordered revision heading") }
      previous = revision
      guard let fence = lines.popFirst(), fence.count >= 3,
        fence.allSatisfy({ $0 == "~" })
      else { throw invalid("\(path) has an unfenced revision body") }
      var body: [String] = []
      while let line = lines.first, line != fence { body.append(lines.removeFirst()) }
      guard lines.popFirst() == fence else { throw invalid("\(path) has an unclosed revision") }
      bodies[number] = body.joined(separator: "\n")
    }
    return bodies
  }

  private func documentRecords(_ path: String, bodies: [String: String]) throws -> [ExportRow] {
    var rank = 0
    var revisions: Set<String> = []
    let records = try lines(path).map { line in
      let table = try row(line, keys: ["table"], in: path).value("table")
      guard let next = ExportFormat.docRecords.firstIndex(where: { $0.table == table }),
        next >= rank
      else { throw invalid("\(path) has an unknown or unordered record group") }
      rank = next
      let keys = ExportFormat.docRecords[next].keys
      let record = try row(line, keys: keys, in: path)
      guard table == "doc_rev" else { return record }
      guard let revision = record.value("rev"), let body = bodies[revision],
        revisions.insert(revision).inserted
      else { throw invalid("\(path) has a duplicate revision or one without a body") }
      return record.replacing("body_md", with: body, keys: keys)
    }
    guard revisions == Set(bodies.keys) else {
      throw invalid("\(path) is missing revision metadata")
    }
    return records
  }
}
