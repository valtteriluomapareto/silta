import Foundation

/// Accepts a bounded single-line subset; unknown TOML syntax is never rewritten.
enum AgentTOML {
  static func acceptsDocument(_ document: String) -> Bool {
    var used: Set<[String]> = [], values: Set<[String]> = []
    var section: [String] = []
    for raw in document.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard accepts(line), !line.hasPrefix("[[") else { return false }
      if line.hasPrefix("[") {
        guard let name = tablePath(line) else { return false }
        guard !used.contains(name) else { return false }
        var prefix: [String] = []
        for part in name {
          prefix.append(part)
          guard !values.contains(prefix) else { return false }
          used.insert(prefix)
        }
        section = name
      } else {
        guard let field = assignment(line) else { return false }
        let name = section + [field.key]
        guard used.insert(name).inserted else { return false }
        values.insert(name)
      }
    }
    return true
  }

  static func accepts(_ line: String) -> Bool {
    guard line.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 || $0 == "\t" })
    else { return false }
    if line.hasPrefix("[") {
      return tablePath(line) != nil
    }
    guard let field = assignment(line) else { return false }
    return acceptsValue(field.value)
  }

  /// Accepts one key, including quoted model slugs, without admitting dotted assignments.
  static func assignment(_ line: String) -> (key: String, value: String)? {
    let pattern = #"^\s*(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*")\s*="#
    guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
    let key = String(line[range].dropLast()).trimmingCharacters(in: .whitespaces)
    guard let path = tablePath("[" + key + "]"), path.count == 1 else { return nil }
    return (path[0], String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
  }

  private static func acceptsValue(_ value: String) -> Bool {
    if value.range(of: #"^'[^'\x00-\x08\x0a-\x1f]*'$"#, options: .regularExpression) != nil {
      return true
    }
    guard !value.contains(#"\/"#),
      value.range(of: #"\\u[dD][89a-fA-F][0-9a-fA-F]{2}"#, options: .regularExpression) == nil
    else { return false }
    do {
      return validValue(
        try JSONSerialization.jsonObject(
          with: Data(value.utf8), options: .fragmentsAllowed))
    } catch { return false }
  }

  /// Decodes table segments without treating dots inside quoted paths as separators.
  static func tablePath(_ line: String) -> [String]? {
    guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
    var rest = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    var parts: [String] = []
    while !rest.isEmpty {
      let quoted = rest.hasPrefix("\"")
      let pattern = quoted ? #"^"(?:[^"\\]|\\.)*""# : #"^[A-Za-z0-9_-]+"#
      guard let range = rest.range(of: pattern, options: .regularExpression) else { return nil }
      let token = String(rest[range])
      if quoted {
        guard acceptsValue(token) else { return nil }
        do { parts.append(try JSONDecoder().decode(String.self, from: Data(token.utf8))) } catch {
          return nil
        }
      } else {
        parts.append(token)
      }
      rest = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      if rest.isEmpty { return parts }
      guard rest.hasPrefix(".") else { return nil }
      rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  private static func validValue(_ value: Any) -> Bool {
    if let array = value as? [Any] { return array.allSatisfy(validValue) }
    if let number = value as? NSNumber { return number.doubleValue.isFinite }
    return value is String
  }
}
