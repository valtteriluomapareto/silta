import SwiftUI

struct DocumentMarkdown: View {
  private let blocks: [MarkdownContent.Block]

  init(_ source: String, title: String? = nil) {
    blocks = MarkdownContent(source, title: title).blocks
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(blocks) { block in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if let prefix = block.prefix { Text(prefix).monospacedDigit() }
          if block.code {
            ScrollView(.horizontal) {
              Text(block.text).font(font(block)).textSelection(.enabled).fixedSize()
            }
          } else {
            Text(block.text).font(font(block)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(block.code ? 12 : 0)
        .background(
          block.code ? Color.secondary.opacity(0.08) : .clear,
          in: RoundedRectangle(cornerRadius: 7))
      }
    }
  }

  private func font(_ block: MarkdownContent.Block) -> Font {
    if block.code { return .system(size: 12, design: .monospaced) }
    switch block.header {
    case 1: return .system(size: 24, weight: .bold)
    case 2: return .system(size: 18, weight: .semibold)
    case 3: return .system(size: 16, weight: .semibold)
    case .some: return .headline
    case nil: return .system(size: 14)
    }
  }
}
