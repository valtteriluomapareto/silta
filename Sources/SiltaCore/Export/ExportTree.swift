package import Foundation
package import GRDB

/// Canonical export trees (spec §15): rendering from the database and the strict
/// reader that accepts only what rendering writes.
package enum ExportTree {
  /// The workspace's tree, path to bytes. Throws `ExportError` or `StorageError`.
  package static func render(_ db: Database, workspace slug: String) throws -> [String: Data] {
    try ExportSnapshot.read(db, workspace: slug).files()
  }

  /// Parses a tree. The manifest must name a schema this binary knows and list exactly
  /// the other files with their sha256, and rendering the parsed snapshot must give
  /// back every file byte for byte, so a tree export would not have written is
  /// `ExportError.invalidTree` and one of a newer schema `StorageError.schemaTooNew`.
  /// This checks the form; whether rows reference each other is left to the caller.
  package static func parse(_ files: [String: Data]) throws -> ExportSnapshot {
    let manifest = try ExportManifest(files[ExportFormat.manifestFile])
    guard StorageSchema.migrator.migrations.contains(manifest.schema) else {
      throw StorageError.schemaTooNew
    }
    let present = Set(files.keys).subtracting([ExportFormat.manifestFile])
    func refuse(_ reason: String) -> ExportError {
      .invalidTree(reason: reason, workspace: manifest.workspace)
    }
    if let extra = present.subtracting(manifest.files.keys).min(by: ExportSnapshot.byteOrder) {
      throw refuse("\(extra) is not in the manifest")
    }
    for (path, digest) in manifest.files.sorted(by: { ExportSnapshot.byteOrder($0.key, $1.key) }) {
      guard let data = files[path] else { throw refuse("\(path) is missing") }
      guard ExportFormat.sha256(data) == digest else {
        throw refuse("\(path) does not match its sha256")
      }
    }
    var reader = Reader(files: files, slug: manifest.workspace)
    let (workspace, sections) = try reader.workspace()
    let prefix = workspace.value("task_prefix") ?? ""
    let tasks = try present.filter { $0.hasPrefix("tasks/") && $0.hasSuffix(".md") }
      .map {
        try reader.task(String($0.dropFirst("tasks/".count).dropLast(".md".count)), prefix: prefix)
      }
      .sorted { Int($0.row.value("seq") ?? "") ?? 0 < Int($1.row.value("seq") ?? "") ?? 0 }
    let snapshot = ExportSnapshot(
      format: manifest.format, schema: manifest.schema, workspace: workspace, sections: sections,
      tasks: tasks,
      links: try reader.jsonl(ExportFormat.linksFile, keys: ExportFormat.linkKeys),
      aliasDecisions: try reader.jsonl(
        ExportFormat.aliasDecisionsFile, keys: ExportFormat.aliasDecisionKeys),
      approvals: try reader.jsonl(ExportFormat.approvalsFile, keys: ExportFormat.approvalKeys))
    let rendered = snapshot.files()
    if let path = files.keys.filter({ rendered[$0] != files[$0] }).min(by: ExportSnapshot.byteOrder)
    {
      throw refuse("\(path) is not in the form export writes")
    }
    return snapshot
  }

  static func invalid(_ reason: String, workspace: String? = nil) -> ExportError {
    .invalidTree(reason: reason, workspace: workspace)
  }
}

/// The parts of `manifest.json` the reader and the target check need.
struct ExportManifest {
  var format: String
  var schema: String
  var workspace: String
  var files: [String: String]

  init(_ data: Data?) throws {
    guard let data else { throw ExportTree.invalid("manifest.json is missing") }
    guard
      let parsed = try? JSONSerialization.jsonObject(with: data),  // refused below
      let object = parsed as? [String: Any],
      let format = object["format"] as? String
    else { throw ExportTree.invalid("manifest.json is not a format manifest") }
    guard ["1", "2"].contains(format) else {
      throw ExportTree.invalid("format \(format) is not a supported format (1 or 2)")
    }
    guard let schema = object["schema"] as? String,
      let workspace = object["workspace"] as? String,
      let list = object["files"] as? [[String: String]]
    else { throw ExportTree.invalid("manifest.json is not a format manifest") }
    self.format = format
    self.schema = schema
    self.workspace = workspace
    files = Dictionary(list.map { ($0["path"] ?? "", $0["sha256"] ?? "") }) { first, _ in first }
  }
}

/// Parses the line grammar of each file; values go through `JSONSerialization`, and
/// whatever it accepts beyond the grammar is caught by the byte comparison afterwards.
private struct Reader {
  let files: [String: Data]
  /// The manifest's workspace, so a refusal can name the tree to export again.
  let slug: String

  func invalid(_ reason: String) -> ExportError {
    ExportTree.invalid(reason, workspace: slug)
  }

  func lines(_ path: String) throws -> [String] {
    var lines = try (files[path] ?? Data()).split(separator: 0x0A, omittingEmptySubsequences: false)
      .map { bytes -> String in
        guard let line = String(bytes: bytes, encoding: .utf8) else {
          throw invalid("\(path) is not UTF-8")
        }
        return line
      }
    guard lines.last == "" else { throw invalid("\(path) does not end with a newline") }
    lines.removeLast()
    return lines
  }

  func row(_ text: some StringProtocol, keys: [String], in path: String) throws -> ExportRow {
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),  // refused below
      let values = object as? [String: String]
    else { throw invalid("\(path) has a row that is not an object of strings") }
    return ExportRow(keys: keys, values: values)
  }

  func jsonl(_ path: String, keys: [String]) throws -> [ExportRow] {
    try lines(path).map { try row($0, keys: keys, in: path) }
  }

  mutating func workspace() throws -> (ExportRow, [ExportSnapshot.Section]) {
    let path = ExportFormat.workspaceFile
    var lines = try lines(path)[...]
    guard let first = lines.popFirst(), first.hasPrefix("workspace: ") else {
      throw invalid("\(path) does not start with the workspace row")
    }
    let workspace = try row(
      first.dropFirst("workspace: ".count), keys: ExportFormat.workspaceKeys, in: path)
    var sections: [ExportSnapshot.Section] = []
    for format in ExportFormat.sections {
      guard let header = lines.popFirst() else {
        throw invalid("\(path) has no \(format.name)")
      }
      var rows: [ExportRow] = []
      if header != "\(format.name): []" {
        guard header == "\(format.name):" else {
          throw invalid("\(path) has no \(format.name)")
        }
        while let next = lines.first, next.hasPrefix("  - ") {
          rows.append(try row(next.dropFirst(4), keys: format.keys, in: path))
          lines.removeFirst()
        }
      }
      sections.append(ExportSnapshot.Section(name: format.name, rows: rows))
    }
    guard lines.isEmpty else { throw invalid("\(path) has lines after the sections") }
    return (workspace, sections)
  }

  /// Reads the `---` block of `key: "value"` lines.
  func frontmatter(_ lines: inout ArraySlice<String>, in path: String) throws -> [String: String] {
    guard lines.popFirst() == "---" else { throw invalid("\(path) has no frontmatter") }
    var values: [String: String] = [:]
    while let line = lines.popFirst(), line != "---" {
      guard let colon = line.range(of: ": "),
        case let key = String(line[..<colon.lowerBound]),
        let value = try? JSONSerialization.jsonObject(  // refused below
          with: Data(line[colon.upperBound...].utf8), options: .fragmentsAllowed) as? String
      else { throw invalid("\(path) has an invalid frontmatter line") }
      values[key] = value
    }
    return values
  }

  func task(_ ref: String, prefix: String) throws -> ExportTask {
    let path = "tasks/\(ref).md"
    var lines = try lines(path)[...]
    var values = try frontmatter(&lines, in: path)
    for body in ExportFormat.bodies {
      guard lines.first == "## \(body.heading)" else {
        if body.key == "result_md" { break }
        throw invalid("\(path) has no \(body.heading) section")
      }
      lines.removeFirst()
      guard let fence = lines.popFirst(), fence.count >= 3, fence.allSatisfy({ $0 == "~" }) else {
        throw invalid("\(path) has an unfenced \(body.heading) section")
      }
      var text: [String] = []
      while let line = lines.popFirst(), line != fence { text.append(line) }
      values[body.key] = text.joined(separator: "\n")
    }
    guard lines.isEmpty else { throw invalid("\(path) has lines after its sections") }
    guard values["ref"] == ref, values["seq"].map({ "\(prefix)-\($0)" }) == ref else {
      throw invalid("\(path) names another task")
    }
    var rank = 0
    let records = try self.lines("tasks/\(ref).jsonl").map { line in
      guard
        let data = line.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data),  // refused below
        let object = parsed as? [String: Any],
        let table = object["table"] as? String,
        let keys = ExportFormat.records.first(where: { $0.table == table })?.keys
      else { throw invalid("tasks/\(ref).jsonl has a row of no known table") }
      // Record groups come in format order: plan revisions, events, comments, requests.
      let next = ExportFormat.records.firstIndex { $0.table == table } ?? 0
      guard next >= rank else {
        throw invalid("tasks/\(ref).jsonl has \(table) rows out of order")
      }
      rank = next
      return try row(line, keys: keys, in: "tasks/\(ref).jsonl")
    }
    return ExportTask(
      ref: ref, row: ExportRow(keys: ExportFormat.taskKeys, values: values), records: records)
  }
}
