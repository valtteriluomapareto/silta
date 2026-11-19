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
  /// shore, rather than as a system inspector column with its own background. Dragging
  /// the gap before it resizes the card.
  func seaInspector<Inspector: View>(
    isPresented: Bool, width: Binding<Double>, @ViewBuilder inspector: () -> Inspector
  ) -> some View {
    HStack(alignment: .top, spacing: 0) {
      frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      if isPresented {
        InspectorResizeHandle(width: width)
        inspector().frame(width: SeaInspectorMetrics.clamped(width.wrappedValue))
          .padding(.bottom, 12)
      }
    }.animation(.smooth(duration: 0.2), value: isPresented)
  }
}

/// The inspector card's width: 340 pt as in the Paper design, resizable within the
/// range the system inspector column allowed.
enum SeaInspectorMetrics {
  static let width: Double = 340
  static let range: ClosedRange<Double> = 300...500
  /// The defaults key both Board and Workspace use, so one width follows the human.
  static let storageKey = "inspectorWidth"

  static func clamped(_ width: Double) -> Double {
    min(max(width, range.lowerBound), range.upperBound)
  }
}

/// The 12 pt gap before the inspector card: drag to resize, double-click to reset.
private struct InspectorResizeHandle: View {
  @Binding var width: Double
  @State private var start: Double?

  var body: some View {
    Color.clear.frame(width: 12).frame(maxHeight: .infinity).contentShape(Rectangle())
      .pointerStyle(.columnResize)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            let origin = start ?? SeaInspectorMetrics.clamped(width)
            start = origin
            width = SeaInspectorMetrics.clamped(origin - value.translation.width)
          }
          .onEnded { _ in start = nil }
      )
      .onTapGesture(count: 2) { width = SeaInspectorMetrics.width }
      .accessibilityElement().accessibilityLabel("Inspector width")
      .accessibilityValue("\(Int(SeaInspectorMetrics.clamped(width))) points")
      .accessibilityAdjustableAction { direction in
        let step: Double = direction == .increment ? 20 : -20
        width = SeaInspectorMetrics.clamped(width + step)
      }
  }
}
