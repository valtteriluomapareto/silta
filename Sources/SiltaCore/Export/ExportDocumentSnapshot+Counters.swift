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

  func minimumFloors(workspace: String? = nil) throws
    -> (revisions: [String: Int64], comments: [Data: (uid: String, next: Int64)])
  {
    var revisions: [String: Int64] = [:]
    var comments: [Data: (uid: String, next: Int64)] = [:]
    for document in documents {
      guard WorkspaceConfig.isValidIdentifier(document.slug), revisions[document.slug] == nil else {
        throw ExportTree.invalid("document slugs must be unique identifiers", workspace: workspace)
      }
      var highest: Int64 = 0
      for record in document.records where record.value("table") == "doc_rev" {
        highest = max(highest, try Self.positive(record.value("rev"), workspace: workspace))
        guard let uid = record.value("uid"), !uid.isEmpty, comments[Data(uid.utf8)] == nil else {
          throw ExportTree.invalid("revision UIDs must be present and unique", workspace: workspace)
        }
        comments[Data(uid.utf8)] = (uid, 1)
      }
      revisions[document.slug] = Self.nextFloor(after: highest)
    }
    for record in documents.flatMap(\.records) where record.value("table") == "comment" {
      guard let owner = record.value("doc_rev"), let floor = comments[Data(owner.utf8)] else {
        throw ExportTree.invalid("a comment has no retained revision owner", workspace: workspace)
      }
      let sequence = try Self.positive(record.value("seq"), workspace: workspace)
      comments[Data(owner.utf8)] = (owner, max(floor.next, Self.nextFloor(after: sequence)))
    }
    return (revisions, comments)
  }

  func validateCounters(workspace: String) throws {
    let floors = try minimumFloors(workspace: workspace)
    try Self.validate(
      revisionAllocations, minimums: floors.revisions, workspace: workspace)
    var values: [Data: Int64] = [:]
    for row in commentSequences {
      guard let owner = row.value("doc_rev"), floors.comments[Data(owner.utf8)] != nil else {
        throw ExportTree.invalid("an allocation has no valid owner", workspace: workspace)
      }
      let next = try Self.positive(row.value("next"), workspace: workspace)
      guard values.updateValue(next, forKey: Data(owner.utf8)) == nil else {
        throw ExportTree.invalid("allocation owners must be unique", workspace: workspace)
      }
    }
    guard
      floors.comments.allSatisfy({ minimum in
        values[minimum.key].map { $0 >= minimum.value.next } ?? false
      })
    else {
      throw ExportTree.invalid(
        "an allocation is missing or collides with retained history", workspace: workspace)
    }
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

  /// UID keys are made from UTF-8 strings and retain their literal spelling.
  static func commentFloorRows(_ values: [Data: (uid: String, next: Int64)]) -> [ExportRow] {
    values.values.sorted { ExportSnapshot.byteOrder($0.uid, $1.uid) }.map {
      ExportRow(keys: ["doc_rev", "next"], values: ["doc_rev": $0.uid, "next": String($0.next)])
    }
  }

  static func floorRows(_ values: [String: Int64], key: String) -> [ExportRow] {
    values.keys.sorted(by: ExportSnapshot.byteOrder).map {
      ExportRow(keys: [key, "next"], values: [key: $0, "next": String(values[$0] ?? 1)])
    }
  }
}
