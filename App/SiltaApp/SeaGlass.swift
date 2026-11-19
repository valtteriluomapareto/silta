import SwiftUI

/// The window's opaque shore gradient. Reduce Transparency drops the glows.
struct ShoreBackground: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color("ShoreStart"), Color("ShoreMiddle"), Color("ShoreEnd")],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      if !reduceTransparency {
        RadialGradient(
          colors: [Color("TideGlow"), .clear], center: UnitPoint(x: 0.05, y: 0), startRadius: 0,
          endRadius: 560)
        RadialGradient(
          colors: [Color("BrassGlow"), .clear], center: .bottomTrailing, startRadius: 0,
          endRadius: 640)
      }
    }.ignoresSafeArea().accessibilityHidden(true)
  }
}

/// A floating pane or card that text can sit on. Increase Contrast comes from the colour
/// assets' high-contrast appearances, so plain fills of Pane, Card and PaneBorder get it too.
struct SeaSurface: ViewModifier {
  var radius: CGFloat = 18
  var raised = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return content.background {
      shape.fill(reduceTransparency ? Color("Canvas") : Color(raised ? "Card" : "Pane"))
        .shadow(color: .black.opacity(raised ? 0.07 : 0), radius: 15, y: 10)
    }
    .overlay {
      shape.strokeBorder(Color("PaneBorder"), lineWidth: 1)
    }
  }
}

extension View {
  func seaPane(radius: CGFloat = 18) -> some View { modifier(SeaSurface(radius: radius)) }
  func seaCard(radius: CGFloat = 18) -> some View {
    modifier(SeaSurface(radius: radius, raised: true))
  }
}

/// An 11 pt capitals section label.
struct Overline: View {
  let text: String
  var color = Color("SecondaryInk")

  init(_ text: String, color: Color = Color("SecondaryInk")) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text).font(.system(size: 11, weight: .semibold)).tracking(1.3).textCase(.uppercase)
      .foregroundStyle(color).accessibilityAddTraits(.isHeader)
  }
}

/// The screen's one large title and its count line.
struct ScreenHeader: View {
  let title: String
  let summary: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.5)
        .accessibilityAddTraits(.isHeader)
      if !summary.isEmpty {
        Text(summary).font(.system(size: 13)).foregroundStyle(Color("ShoreInk"))
          .lineLimit(1)
      }
    }.foregroundStyle(Color("Ink")).frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A two-to-four option switch with a white thumb on a light track.
struct SeaSegments<Value: Hashable>: View {
  let label: String
  let options: [(value: Value, title: String)]
  @Binding var selection: Value

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.value) { option in
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(option.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 12).frame(minHeight: 24).contentShape(.capsule)
        }.buttonStyle(.plain).foregroundStyle(Color("Ink"))
          .background {
            if selected {
              Capsule().fill(Color("Card")).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            }
          }
          .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }.padding(2).background(Color("Ink").opacity(0.06), in: .capsule)
      .accessibilityElement(children: .contain).accessibilityLabel(label)
  }
}

extension View {
  /// Shows an inspector as a Sea glass card beside the content, inside the window's
  /// shore, rather than as a system inspector column with its own background.
  func seaInspector<Inspector: View>(
    isPresented: Bool, @ViewBuilder inspector: () -> Inspector
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      if isPresented {
        inspector().frame(width: SeaInspectorMetrics.width).padding(.bottom, 12)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }.animation(.smooth(duration: 0.2), value: isPresented)
  }
}

/// The inspector card's fixed width, from the Paper design.
enum SeaInspectorMetrics {
  static let width: CGFloat = 340
}
