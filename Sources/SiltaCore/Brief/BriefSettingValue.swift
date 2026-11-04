import Foundation

/// Raw JSON retained by tolerant brief reads, including values from newer writers.
indirect enum BriefSettingValue: Codable, Equatable, Sendable {
  case null, bool(Bool), integer(Int), number(Double), string(String)
  case array([BriefSettingValue]), object([String: BriefSettingValue])

  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let item = Self.probe(Bool.self, from: value) {
      self = .bool(item)
    }  // Probe JSON type.
    else if let item = Self.probe(Int.self, from: value) {
      self = .integer(item)
    } else if let item = Self.probe(Double.self, from: value) {
      self = .number(item)
    }  // Probe JSON type.
    else if let item = Self.probe(String.self, from: value) {
      self = .string(item)
    }  // Probe JSON type.
    else if let item = Self.probe([BriefSettingValue].self, from: value) {
      self = .array(item)
    }  // Probe JSON type.
    else {
      self = .object(try value.decode([String: BriefSettingValue].self))
    }
  }

  private static func probe<T: Decodable>(
    _ type: T.Type, from value: any SingleValueDecodingContainer
  ) -> T? {
    do { return try value.decode(type) } catch { return nil }
  }

  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .bool(let item): try value.encode(item)
    case .integer(let item): try value.encode(item)
    case .number(let item): try value.encode(item)
    case .string(let item): try value.encode(item)
    case .array(let item): try value.encode(item)
    case .object(let item): try value.encode(item)
    }
  }

  var text: String {
    if case .string(let text) = self { return TaskError.shown(text) }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return String(bytes: try encoder.encode(self), encoding: .utf8) ?? "[invalid JSON]"
    } catch { return "[invalid JSON]" }
  }
}
