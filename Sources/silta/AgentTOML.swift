import Foundation

/// Accepts a bounded single-line subset; unknown TOML syntax is never rewritten.
enum AgentTOML {
  static func acceptsDocument(_ document: String) -> Bool {
    var used: Set<String> = [], values: Set<String> = []
    var section = ""
    for raw in document.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard accepts(line), !line.hasPrefix("[[") else { return false }
      if line.hasPrefix("[") {
        let name = String(line.dropFirst().dropLast())
        guard !used.contains(name) else { return false }
        var prefix = ""
        for part in name.split(separator: ".") {
          prefix += (prefix.isEmpty ? "" : ".") + part
          guard !values.contains(prefix) else { return false }
          used.insert(prefix)
        }
        section = name
      } else {
        let key = String(line.split(separator: "=", maxSplits: 1)[0])
          .trimmingCharacters(in: .whitespaces)
        guard !key.contains(".") else { return false }
        let name = (section.isEmpty ? "" : section + ".") + key
        guard used.insert(name).inserted else { return false }
        values.insert(name)
      }
    }
    return true
  }

  static func accepts(_ line: String) -> Bool {
    guard line.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 || $0 == "\t" })
    else { return false }
    let key = #"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*"#
    if line.hasPrefix("[") {
      return line.range(
        of: "^(?:\\[" + key + "\\]|\\[\\[" + key + "\\]\\])$",
        options: .regularExpression) != nil
    }
    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts[0].trimmingCharacters(in: .whitespaces).range(
        of: "^" + key + "$",
        options: .regularExpression) != nil
    else { return false }
    let value = parts[1].trimmingCharacters(in: .whitespaces)
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

  private static func validValue(_ value: Any) -> Bool {
    if let array = value as? [Any] { return array.allSatisfy(validValue) }
    if let number = value as? NSNumber { return number.doubleValue.isFinite }
    return value is String
  }
}
