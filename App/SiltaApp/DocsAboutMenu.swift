import SiltaAppSupport
import SwiftUI

/// Narrows the document list to one app, service or topic with Core's `--about` filter.
struct DocsAboutMenu: View {
  @Bindable var model: AppModel

  var body: some View {
    let selected = model.docsAbout
    HStack(spacing: 8) {
      Menu {
        Button("Any app or topic") { model.docsAbout = nil }
        ForEach(
          DocsContent.aboutOptions(map: model.visibleData?.map, topics: model.documents.topics)
        ) { section in
          Section(section.title) {
            ForEach(section.options, id: \.ref) { option in
              Toggle(
                option.name,
                isOn: Binding(
                  get: { model.docsAbout == option.ref },
                  set: { model.docsAbout = $0 ? option.ref : nil }))
            }
          }
        }
      } label: {
        HStack(spacing: 8) {
          Text("About").foregroundStyle(Color("SecondaryInk"))
          Text(label(selected) ?? "Any app or topic")
            .fontWeight(selected == nil ? .medium : .semibold)
            .foregroundStyle(Color(selected == nil ? "Ink" : "TideText")).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          if selected == nil {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color("SecondaryInk"))
          }
        }.font(.system(size: 12)).contentShape(.rect)
      }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("About")
        .accessibilityValue(label(selected) ?? "Any app or topic")
      if selected != nil {
        Button("Clear filter", systemImage: "xmark") { model.docsAbout = nil }
          .labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color("TideText")).help(selected ?? "")
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 10).fill(
        selected == nil ? Color("Card").opacity(0.7) : Color("TideText").opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(
        selected == nil ? Color("Ink").opacity(0.08) : Color("TideText").opacity(0.2)))
  }

  private func label(_ ref: String?) -> String? {
    ref.map { DocsContent.aboutLabel($0, map: model.visibleData?.map) }
  }

  /// The map colour of an app ref, or a quiet colour for a service, or nil for other refs.
  static func color(_ ref: String, map: AppWorkspaceMap?) -> Color? {
    if ref.hasPrefix("service:") { return Color("SecondaryInk") }
    guard ref.hasPrefix("app:") else { return nil }
    guard let index = map?.apps.firstIndex(where: { $0.attachment == ref }) else {
      return Color("SecondaryInk")
    }
    return Color(SidebarContent.appColor(index: index))
  }
}
