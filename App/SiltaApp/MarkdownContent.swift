import Foundation

nonisolated struct MarkdownContent {
  struct Block: Identifiable {
    let id: Int
    let text: AttributedString
    let header: Int?
    let code: Bool
    let prefix: String?
  }
  let blocks: [Block]

  init(_ source: String, title: String? = nil) {
    var source = source
    if let title, source.hasPrefix("# " + title + "\n") {
      source = String(source.dropFirst(title.count + 3))
    }
    source = Self.readableTables(source)
    do {
      let parsed = try AttributedString(markdown: source)
      blocks = parsed.runs[\.presentationIntent].enumerated().map { offset, run in
        let (intent, range) = run
        let kinds = intent?.components.map(\.kind) ?? []
        let header = kinds.compactMap { kind -> Int? in
          if case .header(let level) = kind { return level }
          return nil
        }.first
        let ordinal = kinds.compactMap { kind -> Int? in
          if case .listItem(let number) = kind { return number }
          return nil
        }.first
        let code = kinds.contains {
          if case .codeBlock = $0 { return true }
          return false
        }
        let prefix = ordinal.map { kinds.contains(.orderedList) ? "\($0)." : "•" }
        return Block(
          id: offset, text: AttributedString(parsed[range]), header: header,
          code: code, prefix: prefix)
      }
    } catch {
      blocks = [Block(id: 0, text: AttributedString(source), header: nil, code: false, prefix: nil)]
    }
  }

  private static func readableTables(_ source: String) -> String {
    let lines = source.components(separatedBy: "\n")
    var result: [String] = []
    var fence: String?
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        let marker = String(trimmed.prefix(3))
        if fence == marker { fence = nil } else if fence == nil { fence = marker }
      }
      if fence == nil, !line.hasPrefix("    "), line.contains("|"), index + 1 < lines.count {
        let separator = lines[index + 1].filter { !$0.isWhitespace && $0 != "|" && $0 != ":" }
        if separator.count >= 3, separator.allSatisfy({ $0 == "-" }) {
          result.append("```text")
          repeat {
            result.append(lines[index])
            index += 1
          } while index < lines.count && lines[index].contains("|") && !lines[index].isEmpty
          result.append("```")
          continue
        }
      }
      result.append(line)
      index += 1
    }
    return result.joined(separator: "\n")
  }
}
