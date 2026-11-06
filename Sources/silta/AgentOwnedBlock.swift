import Foundation

/// A content seal detects edits without depending on the installed binary version.
struct AgentOwnedBlock {
  let outside: String
  let owned: Bool
  let span: String
  let preservedBytes: Int
  let retainsSeparator: Bool
  private let ownsTable: Bool
  private let origin: String
  private let start: String
  private let end: String
  private let seal: String
  private let toml: Bool
  private let offset: Int

  init(_ original: String, toml: Bool, existed: Bool, refusal: () throws -> Never) throws {
    self.toml = toml
    if toml, !AgentTOML.acceptsDocument(original) { try refusal() }
    start = toml ? "\n# silta:begin " : "\n<!-- silta:begin "
    end = toml ? "# silta:end\n" : "<!-- silta:end -->\n"
    seal = toml ? "\n" : " -->\n"
    var text = original
    var origin = existed ? "keep" : "new"
    var offset = text.count
    var hadOwnership = false
    var span = ""
    var ownsTable = false
    var preservedBytes = 0
    var retainsSeparator = false
    if let begin = text.range(of: start), let finish = text.range(of: end),
      begin.upperBound < finish.lowerBound,
      let header = text.range(of: seal, range: begin.upperBound..<finish.lowerBound)
    {
      let fields = text[begin.upperBound..<header.lowerBound].split(separator: ":")
      guard fields.count == 2, ["keep", "new"].contains(fields[1]) else { try refusal() }
      let content = String(text[header.upperBound..<finish.lowerBound])
      let owned = try Self.authenticatedPrefix(
        content, fields: fields, toml: toml, refusal: refusal)
      let foreign = String(content.dropFirst(owned.count))
      origin = String(fields[1])
      ownsTable = toml && owned.hasPrefix("[sandbox_workspace_write]\n")
      if ownsTable {
        try Self.validateTableTail(foreign + text[finish.upperBound...], refusal: refusal)
      } else if toml {
        try Self.validateGrantScope(String(text[..<begin.lowerBound]), refusal: refusal)
      }
      span = String(text[begin.lowerBound..<header.upperBound]) + owned + end
      offset = text.distance(from: text.startIndex, to: begin.lowerBound)
      retainsSeparator =
        toml
        && Self.needsSeparator(
          text[..<begin.lowerBound], before: foreign + text[finish.upperBound...])
      text.replaceSubrange(
        begin.lowerBound..<finish.upperBound, with: (retainsSeparator ? "\n" : "") + foreign)
      preservedBytes = foreign.utf8.count
      hadOwnership = true
    }
    if text.contains("silta:begin") || text.contains("silta:end") { try refusal() }
    self.outside = text
    self.origin = origin
    self.offset = offset
    self.owned = hadOwnership
    self.span = span
    self.ownsTable = ownsTable
    self.preservedBytes = preservedBytes
    self.retainsSeparator = retainsSeparator
  }

  private static func needsSeparator(_ prefix: Substring, before tail: String) -> Bool {
    !prefix.isEmpty && !prefix.hasSuffix("\n") && !tail.isEmpty && !tail.hasPrefix("\n")
  }

  private static func authenticatedPrefix(
    _ content: String, fields: [Substring], toml: Bool, refusal: () throws -> Never
  ) throws -> String {
    let owned = toml ? try Self.grantPrefix(content, refusal: refusal) : content
    guard AgentInstallPlan.hash(Data((fields[1] + ":" + owned).utf8)) == fields[0] else {
      try refusal()
    }
    return owned
  }

  func render(_ body: String, refusal: () throws -> Never) throws -> String {
    var text = outside
    var insertion = text.index(text.startIndex, offsetBy: offset)
    var content = body
    if toml {
      let tableEnd = try tomlTableEnd(refusal: refusal)
      // The block supplies the separator while installed; removal retains it when needed.
      if retainsSeparator { text.remove(at: insertion) }
      if ownsTable {
        guard tableEnd == nil else { try refusal() }
        content = "[sandbox_workspace_write]\n" + body
      } else if let tableEnd {
        if !owned { insertion = tableEnd }
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

  private static func grantPrefix(_ content: String, refusal: () throws -> Never) throws -> String {
    let table = "[sandbox_workspace_write]\n"
    let hasTable = content.hasPrefix(table)
    let rest = hasTable ? String(content.dropFirst(table.count)) : content
    guard let newline = rest.firstIndex(of: "\n") else { try refusal() }
    let line = String(rest[..<newline])
    let key = "writable_roots = "
    guard line.hasPrefix(key) else { try refusal() }
    let roots: [String]
    do {
      roots = try JSONDecoder().decode([String].self, from: Data(line.dropFirst(key.count).utf8))
    } catch { try refusal() }
    guard roots.count == 1, roots[0].hasPrefix("/") else { try refusal() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    guard let canonical = String(bytes: try encoder.encode(roots), encoding: .utf8) else {
      try refusal()
    }
    guard line == key + canonical else { try refusal() }
    return (hasTable ? table : "") + line + "\n"
  }

  private static func validateGrantScope(_ prefix: String, refusal: () throws -> Never) throws {
    let section = prefix.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.last { $0.hasPrefix("[") }
    guard let section, AgentTOML.tablePath(section) == ["sandbox_workspace_write"] else {
      try refusal()
    }
  }

  private static func validateTableTail(_ tail: String, refusal: () throws -> Never) throws {
    let first = tail.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.first { !$0.isEmpty && !$0.hasPrefix("#") }
    if let first, !first.hasPrefix("[") { try refusal() }
  }

  private func tomlTableEnd(refusal: () throws -> Never) throws -> String.Index? {
    var position = outside.startIndex
    var section: [String]?
    var tableEnd: String.Index?
    for line in outside.components(separatedBy: "\n") {
      let text = line.trimmingCharacters(in: .whitespaces)
      let next =
        outside.index(position, offsetBy: line.count + 1, limitedBy: outside.endIndex)
        ?? outside.endIndex
      if !text.isEmpty, !text.hasPrefix("#") {
        try Self.validateTOMLLine(text, refusal: refusal)
        if text.hasPrefix("[") {
          section = AgentTOML.tablePath(text)
          if section == ["sandbox_workspace_write"] {
            guard tableEnd == nil else { try refusal() }
            tableEnd = next
          }
        } else if section == ["sandbox_workspace_write"],
          AgentTOML.assignment(text)?.key == "writable_roots"
        {
          try refusal()
        }
      }
      position = next
    }
    return tableEnd
  }

  private static func validateTOMLLine(_ text: String, refusal: () throws -> Never) throws {
    guard AgentTOML.accepts(text) else { try refusal() }
    if let path = AgentTOML.tablePath(text), path.first == "sandbox_workspace_write",
      path != ["sandbox_workspace_write"]
    {
      try refusal()
    }
  }
}
