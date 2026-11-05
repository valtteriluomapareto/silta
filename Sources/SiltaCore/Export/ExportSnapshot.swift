import CryptoKit
package import Foundation
import GRDB

/// One exported row: its keys in format order, NULL columns left out (spec §15).
package struct ExportRow: Equatable, Sendable {
  /// Key and value pairs in the order they are written.
  package var fields: [Field]

  /// A key and its value as written.
  package struct Field: Equatable, Sendable {
    /// The column or reference name.
    package var key: String
    /// The stored text, or an integer in decimal.
    package var value: String

    /// Compares the literal UTF-8 bytes, not canonical equivalence.
    package static func == (left: Self, right: Self) -> Bool {
      left.key == right.key && left.value.utf8.elementsEqual(right.value.utf8)
    }
  }

  /// The value under `key`, or nil when the column was NULL.
  package func value(_ key: String) -> String? {
    fields.first { $0.key == key }?.value
  }

  /// The fields of `values` whose keys are in `keys`, in that order.
  init(keys: [String], values: [String: String]) {
    fields = keys.compactMap { key in values[key].map { Field(key: key, value: $0) } }
  }

  /// Reads `keys` from a result row; a NULL column is left out.
  init(keys: [String], row: Row) throws {
    var values: [String: String] = [:]
    for key in keys {
      let value: DatabaseValue = row[key]
      switch value.storage {
      case .null: continue
      case .int64(let number): values[key] = String(number)
      case .string(let text): values[key] = text
      case .double, .blob: throw ExportError.unsupported("non-text values in \(key)")
      }
    }
    self.init(keys: keys, values: values)
  }
}

/// A task file pair: the task row (bodies included) and its jsonl records.
package struct ExportTask: Equatable, Sendable {
  /// The display ref that names the files.
  package var ref: String
  /// The task row, `ref` first.
  package var row: ExportRow
  /// Plan revisions, events, comments and review requests, `table` first.
  package var records: [ExportRow]
}

/// A workspace as format 1 holds it, independent of integer ids.
package struct ExportSnapshot: Equatable, Sendable {
  /// The last applied migration.
  package var schema: String
  /// The workspace row.
  package var workspace: ExportRow
  /// `workspace.yaml` sections in file order.
  package var sections: [Section]
  /// Tasks in id order.
  package var tasks: [ExportTask]
  /// `links.jsonl` rows.
  package var links: [ExportRow]
  /// `alias_decisions.jsonl` rows.
  package var aliasDecisions: [ExportRow]
  /// `approvals.jsonl` rows.
  package var approvals: [ExportRow]

  /// A named `workspace.yaml` section.
  package struct Section: Equatable, Sendable {
    /// The section name, e.g. `repos`.
    package var name: String
    /// Its rows in id order.
    package var rows: [ExportRow]
  }

  /// The tree's files keyed by relative path, `manifest.json` included.
  package func files() -> [String: Data] {
    var files: [String: String] = [
      ExportFormat.workspaceFile: workspaceYAML(),
      ExportFormat.linksFile: ExportFormat.jsonl(links),
      ExportFormat.aliasDecisionsFile: ExportFormat.jsonl(aliasDecisions),
      ExportFormat.approvalsFile: ExportFormat.jsonl(approvals),
    ]
    for task in tasks {
      files["tasks/\(task.ref).md"] = Self.markdown(task.row)
      files["tasks/\(task.ref).jsonl"] = ExportFormat.jsonl(task.records)
    }
    var data = files.mapValues { Data($0.utf8) }
    data[ExportFormat.manifestFile] = Data(manifest(data).utf8)
    return data
  }

  private func workspaceYAML() -> String {
    "workspace: " + ExportFormat.line(workspace) + "\n"
      + sections.map { section in
        section.rows.isEmpty
          ? "\(section.name): []\n"
          : "\(section.name):\n"
            + section.rows.map { "  - " + ExportFormat.line($0) + "\n" }.joined()
      }.joined()
  }

  /// Frontmatter of every non-body field, then the fenced bodies (spec §15).
  static func markdown(_ row: ExportRow) -> String {
    let bodies = Set(ExportFormat.bodies.map(\.key))
    let fence = TaskEditDocument.fence(
      for: row.fields.filter { bodies.contains($0.key) }.map(\.value))
    var text = "---\n"
    for field in row.fields where !bodies.contains(field.key) {
      text += field.key + ": " + ExportFormat.quote(field.value) + "\n"
    }
    text += "---\n"
    for body in ExportFormat.bodies {
      guard let value = row.value(body.key) else { continue }
      text += "## \(body.heading)\n\(fence)\n\(value)\n\(fence)\n"
    }
    return text
  }

  private func manifest(_ files: [String: Data]) -> String {
    var counts: [String: Int] = ["workspace": 1, "task": tasks.count]
    for (section, format) in zip(sections, ExportFormat.sections) {
      counts[format.table] = section.rows.count
    }
    for record in ExportFormat.records {
      counts[record.table] =
        tasks.map { $0.records.filter { $0.value("table") == record.table }.count }.reduce(0, +)
    }
    counts["link"] = links.count
    counts["alias_decision"] = aliasDecisions.count
    counts["approval"] = approvals.count
    let countLine = counts.keys.sorted(by: Self.byteOrder).map {
      ExportFormat.quote($0) + ": " + ExportFormat.quote(String(counts[$0] ?? 0))
    }.joined(separator: ", ")
    let entries = files.keys.sorted(by: Self.byteOrder).map { path in
      let digest = SHA256.hash(data: files[path] ?? Data()).map { String(format: "%02x", $0) }
      return "    {\"path\": \(ExportFormat.quote(path)), \"sha256\": \"\(digest.joined())\"}"
    }
    return """
      {
        "format": \(ExportFormat.quote(ExportFormat.version)),
        "schema": \(ExportFormat.quote(schema)),
        "workspace": \(ExportFormat.quote(workspace.value("slug") ?? "")),
        "counts": {\(countLine)},
        "files": [
      \(entries.joined(separator: ",\n"))
        ]
      }

      """
  }

  static func byteOrder(_ left: String, _ right: String) -> Bool {
    left.utf8.lexicographicallyPrecedes(right.utf8)
  }
}
