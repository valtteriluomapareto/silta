import Foundation
import SwiftUI

struct DocumentMarkdown: View {
  private struct Block: Identifiable {
    let id: Int
    let text: AttributedString
    let header: Int?
    let code: Bool
    let prefix: String?
  }
  private let blocks: [Block]

  init(_ source: String) {
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(blocks) { block in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if let prefix = block.prefix { Text(prefix).monospacedDigit() }
          Text(block.text).font(font(block)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(block.code ? 12 : 0)
        .background(
          block.code ? Color.secondary.opacity(0.08) : .clear,
          in: RoundedRectangle(cornerRadius: 7))
      }
    }
  }

  private func font(_ block: Block) -> Font {
    if block.code { return .system(.callout, design: .monospaced) }
    switch block.header {
    case 1: return .title.bold()
    case 2: return .title2.bold()
    case 3: return .title3.bold()
    case .some: return .headline
    case nil: return .body
    }
  }
}
