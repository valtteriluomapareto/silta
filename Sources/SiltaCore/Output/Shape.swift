/// The shape of a command's `--json` data, as `silta schema` publishes it (spec §20.1):
/// `"string"`, `"int"`, `"bool"`, `"any"`, `{"array":S}`, `{"optional":S}` or
/// `{"object":{…}}`.
package indirect enum Shape: Encodable, Equatable, Sendable {
  /// A JSON string.
  case string
  /// A JSON integer.
  case int
  /// A JSON boolean.
  case bool
  /// Any JSON value.
  case any
  /// A JSON array whose elements have this shape.
  case array(Shape)
  /// An object field that may be absent.
  case optional(Shape)
  /// A JSON object with exactly these fields.
  case object([String: Shape])

  private enum Key: String, CodingKey {
    case array, optional, object
  }

  package func encode(to encoder: any Encoder) throws {
    switch self {
    case .string, .int, .bool, .any:
      var container = encoder.singleValueContainer()
      try container.encode(String(describing: self))
    case .array(let element):
      var container = encoder.container(keyedBy: Key.self)
      try container.encode(element, forKey: .array)
    case .optional(let wrapped):
      var container = encoder.container(keyedBy: Key.self)
      try container.encode(wrapped, forKey: .optional)
    case .object(let fields):
      var container = encoder.container(keyedBy: Key.self)
      try container.encode(fields, forKey: .object)
    }
  }
}
