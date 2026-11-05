import Foundation

/// A content seal detects edits without depending on the installed binary version.
struct AgentOwnedBlock {
  let outside: String
  let owned: Bool
  private let origin: String
  private let start: String
  private let end: String
  private let seal: String
  private let toml: Bool
  private let offset: Int

  init(_ original: String, toml: Bool, existed: Bool, refusal: () throws -> Never) throws {
    self.toml = toml
    start = toml ? "\n# silta:begin " : "\n<!-- silta:begin "
    end = toml ? "# silta:end\n" : "<!-- silta:end -->\n"
    seal = toml ? "\n" : " -->\n"
    var text = original
    var origin = existed ? "keep" : "new"
    var offset = text.count
    var hadOwnership = false
    if let begin = text.range(of: start), let finish = text.range(of: end),
      begin.upperBound < finish.lowerBound,
      let header = text.range(of: seal, range: begin.upperBound..<finish.lowerBound)
    {
      let fields = text[begin.upperBound..<header.lowerBound].split(separator: ":")
      guard fields.count == 2, ["keep", "new"].contains(fields[1]) else { try refusal() }
      let owned = String(text[header.upperBound..<finish.lowerBound])
      origin = String(fields[1])
      guard AgentInstallPlan.hash(Data((origin + ":" + owned).utf8)) == fields[0] else {
        try refusal()
      }
      if toml, owned.hasPrefix("[sandbox_workspace_write]\n") {
        try Self.validateTableTail(String(text[finish.upperBound...]), refusal: refusal)
      }
      offset = text.distance(from: text.startIndex, to: begin.lowerBound)
      text.removeSubrange(begin.lowerBound..<finish.upperBound)
      hadOwnership = true
    }
    if text.contains("silta:begin") || text.contains("silta:end") { try refusal() }
    self.outside = text
    self.origin = origin
    self.offset = offset
    self.owned = hadOwnership
  }

  func render(_ body: String, refusal: () throws -> Never) throws -> String {
    var text = outside
    var insertion = text.index(text.startIndex, offsetBy: offset)
    var content = body
    if toml {
      if let tableEnd = try tomlTableEnd(refusal: refusal) {
        insertion = tableEnd
      } else {
        insertion = text.endIndex
        content = "[sandbox_workspace_write]\n" + body
      }
    }
    let block =
      start + AgentInstallPlan.hash(Data((origin + ":" + content).utf8)) + ":" + origin
      + seal + content + end
    text.insert(contentsOf: block, at: insertion)
    return text
  }

  private static func validateTableTail(_ tail: String, refusal: () throws -> Never) throws {
    let first = tail.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.first { !$0.isEmpty && !$0.hasPrefix("#") }
    if let first, !first.hasPrefix("[") { try refusal() }
  }

  private func tomlTableEnd(refusal: () throws -> Never) throws -> String.Index? {
    var position = outside.startIndex
    var section: String?
    var tableEnd: String.Index?
    for line in outside.components(separatedBy: "\n") {
      let text = line.trimmingCharacters(in: .whitespaces)
      let next =
        outside.index(position, offsetBy: line.count + 1, limitedBy: outside.endIndex)
        ?? outside.endIndex
      if !text.isEmpty, !text.hasPrefix("#") {
        try Self.validateTOMLLine(text, refusal: refusal)
        if text.hasPrefix("[") {
          section = text
          if section == "[sandbox_workspace_write]" {
            guard tableEnd == nil else { try refusal() }
            tableEnd = next
          }
        } else if section == "[sandbox_workspace_write]", text.hasPrefix("writable_roots") {
          try refusal()
        }
      }
      position = next
    }
    return tableEnd
  }

  private static func validateTOMLLine(_ text: String, refusal: () throws -> Never) throws {
    guard AgentTOML.accepts(text),
      !text.contains("sandbox_workspace_write") || text == "[sandbox_workspace_write]"
    else { try refusal() }
  }
}
