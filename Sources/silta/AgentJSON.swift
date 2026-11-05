import Foundation
import SiltaCore

/// Refuses duplicate keys and numbers outside the exact safe-integer subset.
enum AgentJSON {
  private struct Frame {
    let object: Bool
    var keys: Set<String> = []
    var key: Bool
  }

  static func object(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { throw TaskError.input }
    let bytes = Array(text.utf8)
    var index = 0
    var frames: [Frame] = []
    while index < bytes.count {
      switch bytes[index] {
      case 123, 91:
        frames.append(Frame(object: bytes[index] == 123, key: bytes[index] == 123))
      case 125, 93: _ = frames.popLast()
      case 44:
        if let last = frames.indices.last { frames[last].key = frames[last].object }
      case 34: try string(bytes, index: &index, frames: &frames)
      case 45, 48...57:
        try number(bytes, index: &index)
        continue
      default: break
      }
      index += 1
    }
    return object
  }

  private static func string(_ bytes: [UInt8], index: inout Int, frames: inout [Frame]) throws {
    let start = index
    index = stringEnd(bytes, after: index)
    guard index < bytes.count else { throw TaskError.input }
    if let last = frames.indices.last, frames[last].key {
      let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
      guard frames[last].keys.insert(key).inserted else { throw TaskError.input }
      frames[last].key = false
    }
  }

  private static func number(_ bytes: [UInt8], index: inout Int) throws {
    let start = index
    let characters = Set("-+.eE0123456789".utf8)
    while index < bytes.count, characters.contains(bytes[index]) { index += 1 }
    let raw = String(bytes: bytes[start..<index], encoding: .utf8) ?? ""
    guard let value = Int64(raw), (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value)
    else { throw TaskError.input }
  }

  private static func stringEnd(_ bytes: [UInt8], after start: Int) -> Int {
    var index = start + 1
    while index < bytes.count, bytes[index] != 34 {
      index += bytes[index] == 92 ? 2 : 1
    }
    return index
  }
}
