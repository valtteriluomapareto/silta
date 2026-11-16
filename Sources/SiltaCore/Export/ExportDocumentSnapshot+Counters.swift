import Foundation

extension ExportDocumentSnapshot {
  /// Saturates exhausted owners instead of incrementing beyond SQLite's integer range.
  static func nextFloor(after highest: Int64) -> Int64 {
    highest == Int64.max ? Int64.max : highest + 1
  }

  static func positive(_ text: String?, workspace: String? = nil) throws -> Int64 {
    guard let text, let number = Int64(text), number > 0, String(number) == text else {
      throw ExportTree.invalid(
        "document sequences and floors must be positive decimal integers", workspace: workspace)
    }
    return number
  }

  func minimumRevisionFloors(workspace: String? = nil) throws -> [String: Int64] {
    var revisions: [String: Int64] = [:]
    for document in documents {
      guard WorkspaceConfig.isValidIdentifier(document.slug), revisions[document.slug] == nil else {
        throw ExportTree.invalid("document slugs must be unique identifiers", workspace: workspace)
      }
      var highest: Int64 = 0
      for record in document.records where record.value("table") == "doc_rev" {
        highest = max(highest, try Self.positive(record.value("rev"), workspace: workspace))
      }
      revisions[document.slug] = Self.nextFloor(after: highest)
    }
    return revisions
  }

  func validateCounters(workspace: String) throws {
    try Self.validate(
      revisionAllocations, minimums: minimumRevisionFloors(workspace: workspace),
      workspace: workspace)
  }

  private static func validate(
    _ rows: [ExportRow], minimums: [String: Int64],
    workspace: String
  ) throws {
    var values: [String: Int64] = [:]
    for row in rows {
      guard let owner = row.value("slug"), WorkspaceConfig.isValidIdentifier(owner)
      else { throw ExportTree.invalid("an allocation has no valid owner", workspace: workspace) }
      let next = try positive(row.value("next"), workspace: workspace)
      guard values.updateValue(next, forKey: owner) == nil else {
        throw ExportTree.invalid("allocation owners must be unique", workspace: workspace)
      }
    }
    guard
      minimums.allSatisfy({ minimum in
        values[minimum.key].map { $0 >= minimum.value } ?? false
      })
    else {
      throw ExportTree.invalid(
        "an allocation is missing or collides with retained history", workspace: workspace)
    }
  }

  static func floorRows(_ values: [String: Int64], key: String) -> [ExportRow] {
    values.keys.sorted(by: ExportSnapshot.byteOrder).map {
      ExportRow(keys: [key, "next"], values: [key: $0, "next": String(values[$0] ?? 1)])
    }
  }
}
