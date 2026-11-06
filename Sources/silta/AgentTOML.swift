import Foundation

/// Edits only the effective Silta root in a narrowly supported, single-line string array.
enum AgentTOML {
  private static let table = "[sandbox_workspace_write]"
  private static let string = #""(?:[^"\\]|\\.)*""#

  static func replace(
    _ document: String, value: String, uninstall: Bool, refusal: () throws -> Never
  ) throws -> String {
    let (tableEnd, arrayRange) = try locate(document, refusal: refusal)
    var result = document
    if let arrayRange {
      let array = try editArray(
        String(document[arrayRange]), value: value, uninstall: uninstall, refusal: refusal)
      result.replaceSubrange(arrayRange, with: array)
    } else if !uninstall {
      let position = tableEnd ?? document.endIndex
      let separator =
        position == document.startIndex || document[..<position].hasSuffix("\n") ? "" : "\n"
      let header = tableEnd == nil ? table + "\n" : ""
      result.insert(contentsOf: separator + header + "writable_roots = [\(value)]\n", at: position)
    }
    return result
  }

  private static func locate(
    _ document: String, refusal: () throws -> Never
  ) throws -> (String.Index?, Range<String.Index>?) {
    var section = "", names: Set<String> = []
    var tableEnd: String.Index?, array: Range<String.Index>?
    for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.isEmpty || text.hasPrefix("#") { continue }
      guard !text.contains("\"\"\""), !text.contains("'''"),
        text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 || $0 == "\t" })
      else { try refusal() }
      if text.hasPrefix("[") {
        guard text.range(of: #"^\[[^\[\]\\]+\]$"#, options: .regularExpression) != nil,
          !text.contains("sandbox_workspace_write") || text == table
        else { try refusal() }
        if section == table { tableEnd = line.startIndex }
        section = text
        guard names.insert(String(text.dropFirst().dropLast())).inserted else { try refusal() }
        if section == table { tableEnd = document.endIndex }
      } else {
        if let found = try valueRange(line, section: section, names: &names, refusal: refusal) {
          array = found
        }
      }
    }
    return (tableEnd, array)
  }

  private static func valueRange(
    _ line: Substring, section: String, names: inout Set<String>, refusal: () throws -> Never
  ) throws -> Range<String.Index>? {
    guard let equal = line.firstIndex(of: "=") else { try refusal() }
    let key = line[..<equal].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
    guard !key.contains("\\"), !key.contains("sandbox_workspace_write"),
      key.range(of: #"^(?:[A-Za-z0-9_-]+|"[^"\\]*")$"#, options: .regularExpression) != nil,
      names.insert((section.isEmpty ? "" : String(section.dropFirst().dropLast()) + ".") + key)
        .inserted,
      acceptsValue(value)
    else { try refusal() }
    if section == table {
      guard !key.contains("writable_roots") || key == "writable_roots" else { try refusal() }
      if key == "writable_roots" {
        guard value.hasPrefix("["), value.hasSuffix("]"),
          let range = line.range(of: value, range: line.index(after: equal)..<line.endIndex)
        else { try refusal() }
        return range
      }
    }
    return nil
  }

  private static func editArray(
    _ original: String, value: String, uninstall: Bool, refusal: () throws -> Never
  ) throws -> String {
    let pattern = "^\\[\\s*(?:" + string + "(?:\\s*,\\s*" + string + ")*)?\\s*\\]$"
    guard original.range(of: pattern, options: .regularExpression) != nil else { try refusal() }
    let paths: [String], root: String
    do {
      paths = try JSONDecoder().decode([String].self, from: Data(original.utf8))
      root = try JSONDecoder().decode(String.self, from: Data(value.utf8))
    } catch { try refusal() }
    let matches = paths.indices.filter { paths[$0].utf8.elementsEqual(root.utf8) }
    guard matches.count <= 1 else { try refusal() }
    let tokens = original.matches(of: /"(?:[^"\\]|\\.)*"/).map(\.range)
    guard tokens.count == paths.count else { try refusal() }
    var array = original
    if let match = matches.first {
      if !uninstall { return original }
      let token = tokens[match]
      let comma =
        match > 0
        ? array[..<token.lowerBound].lastIndex(of: ",")
        : array[token.upperBound...].firstIndex(of: ",")
      var removals = [token]
      if let comma { removals.append(comma..<array.index(after: comma)) }
      for range in removals.sorted(by: { $0.lowerBound > $1.lowerBound }) {
        array.removeSubrange(range)
      }
    } else if !uninstall {
      array.insert(
        contentsOf: (tokens.isEmpty ? "" : ", ") + value,
        at: tokens.last?.upperBound ?? array.index(before: array.endIndex))
    }
    return array
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
        try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed))
    } catch { return false }
  }

  private static func validValue(_ value: Any) -> Bool {
    if let array = value as? [Any] { return array.allSatisfy(validValue) }
    if let number = value as? NSNumber { return number.doubleValue.isFinite }
    return value is String
  }
}
