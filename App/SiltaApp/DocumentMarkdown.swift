import SwiftUI

struct DocumentMarkdown: View {
  private let blocks: [MarkdownContent.Block]

  init(_ source: String, title: String? = nil) {
    blocks = MarkdownContent(source, title: title).blocks
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(blocks) { block in
        if let table = block.table {
          MarkdownTable(table: table)
        } else {
          paragraph(block)
        }
      }
    }
    .environment(\.openURL, Self.linkAction())
  }

  private func paragraph(_ block: MarkdownContent.Block) -> some View {
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

  /// Checks the destination again before handing it to the system.
  static func linkAction(
    open: @escaping @Sendable (URL) -> OpenURLAction.Result = { .systemAction($0) }
  ) -> OpenURLAction {
    OpenURLAction { url in
      MarkdownContent.destination(for: url) == nil ? .discarded : open(url)
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

/// A GitHub table with a semibold header row. Columns fit their content and the last one
/// wraps; the table scrolls sideways only when the other columns alone are too wide.
private struct MarkdownTable: View {
  let table: MarkdownContent.Table

  var body: some View {
    ViewThatFits(in: .horizontal) {
      grid
      ScrollView(.horizontal) { grid }
    }
  }

  private var grid: some View {
    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
      row(table.header, header: true)
      ForEach(table.rows.indices, id: \.self) { index in
        Divider().gridCellUnsizedAxes(.horizontal)
        row(table.rows[index], header: false)
      }
    }
    .textSelection(.enabled)
    .overlay {
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color("Ink").opacity(0.08))
    }
    .clipShape(.rect(cornerRadius: 10))
  }

  private func row(_ cells: [AttributedString], header: Bool) -> some View {
    GridRow {
      ForEach(cells.indices, id: \.self) { column in
        Text(cells[column]).font(.system(size: 12, weight: header ? .semibold : .regular))
          .foregroundStyle(Color(header ? "SecondaryInk" : "Ink"))
          .multilineTextAlignment(text(table.alignments[column]))
          .fixedSize(horizontal: column < cells.count - 1, vertical: false)
          .gridColumnAlignment(horizontal(table.alignments[column]))
          .padding(.horizontal, 10).padding(.vertical, 7)
          .frame(
            minWidth: column == cells.count - 1 ? 160 : nil,
            idealWidth: column == cells.count - 1 ? 160 : nil,
            maxWidth: column == cells.count - 1 ? .infinity : nil,
            alignment: Alignment(
              horizontal: horizontal(table.alignments[column]), vertical: .center)
          )
          .accessibilityAddTraits(header ? .isHeader : [])
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func horizontal(_ alignment: MarkdownContent.Alignment) -> HorizontalAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private func text(_ alignment: MarkdownContent.Alignment) -> TextAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}
