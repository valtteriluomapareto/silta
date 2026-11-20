import Foundation

nonisolated struct MarkdownContent {
  struct Block: Identifiable {
    let id: Int
    let text: AttributedString
    let header: Int?
    let code: Bool
    let prefix: String?
    var table: Table?
  }
  struct Table {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let trailing: [Bool]
  }
  let blocks: [Block]

  init(_ source: String, title: String? = nil) {
    var source = source
    if let title, source.hasPrefix("# " + title + "\n") {
      source = String(source.dropFirst(title.count + 3))
    }
    do {
      let parsed = try AttributedString(markdown: source)
      var tables = TableBuilder()
      var flowing: [Block] = []
      for (offset, run) in parsed.runs[\.presentationIntent].enumerated() {
        let components = run.0?.components ?? []
        let text = Self.checkedLinks(AttributedString(parsed[run.1]))
        if tables.add(components, text: text) { continue }
        flowing.append(Self.block(id: offset, kinds: components.map(\.kind), text: text))
      }
      blocks = Self.placing(tables.tables, in: flowing)
    } catch {
      blocks = [Block(id: 0, text: AttributedString(source), header: nil, code: false, prefix: nil)]
    }
  }

  /// Returns the exact absolute destination accepted by rendering and activation.
  static func destination(for url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host(), !host.isEmpty
    else { return nil }
    return url.absoluteString
  }

  private static func checkedLinks(_ text: AttributedString) -> AttributedString {
    var output = AttributedString()
    for (url, range) in text.runs[\.link] {
      var run = AttributedString(text[range])
      if let url {
        if let destination = destination(for: url) {
          // A bare URL already shows its destination; only labelled links get the suffix.
          if String(run.characters) != destination {
            run.append(AttributedString(" (\(destination))"))
          }
        } else {
          run.link = nil
        }
      }
      output.append(run)
    }
    return output
  }

  private static func block(id: Int, kinds: [PresentationIntent.Kind], text: AttributedString)
    -> Block
  {
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
    return Block(id: id, text: text, header: header, code: code, prefix: prefix)
  }

  /// Puts each finished table where its first cell appeared among the other blocks.
  private static func placing(_ tables: [TableBuilder.Pending], in blocks: [Block]) -> [Block] {
    var result: [Block] = []
    var remaining = tables[...]
    for block in blocks {
      while let table = remaining.first, table.position <= block.id {
        result.append(table.block)
        remaining = remaining.dropFirst()
      }
      result.append(block)
    }
    return result + remaining.map(\.block)
  }
}

/// Collects GitHub table cells by table, row and column index, so empty cells keep their place.
nonisolated private struct TableBuilder {
  struct Pending {
    let identity: Int
    let position: Int
    let columns: [PresentationIntent.TableColumn]
    var cells: [Int: [Int: AttributedString]] = [:]
    var block: MarkdownContent.Block {
      let rows = (cells.keys.max() ?? 0)
      func row(_ index: Int) -> [AttributedString] {
        (0..<columns.count).map { cells[index]?[$0] ?? AttributedString() }
      }
      return MarkdownContent.Block(
        id: position, text: AttributedString(), header: nil, code: false, prefix: nil,
        table: MarkdownContent.Table(
          header: row(0), rows: rows == 0 ? [] : (1...rows).map(row),
          trailing: columns.map { $0.alignment == .right }))
    }
  }
  private(set) var tables: [Pending] = []
  private var next = 0

  /// Records a table cell and returns true, or returns false for any other block.
  mutating func add(_ components: [PresentationIntent.IntentType], text: AttributedString) -> Bool {
    defer { next += 1 }
    var column: Int?
    var row: Int?
    var table: (Int, [PresentationIntent.TableColumn])?
    for component in components {
      switch component.kind {
      case .tableCell(let index): column = index
      case .tableHeaderRow: row = 0
      case .tableRow(let index): row = index
      case .table(let columns): table = (component.identity, columns)
      default: break
      }
    }
    guard let column, let row, let table else { return false }
    if tables.last?.identity != table.0 {
      tables.append(Pending(identity: table.0, position: next, columns: table.1))
    }
    tables[tables.count - 1].cells[row, default: [:]][column] = text
    return true
  }
}
