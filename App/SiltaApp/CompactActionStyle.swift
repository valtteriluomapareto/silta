import SwiftUI

/// A 28 pt pill for secondary actions.
struct CompactActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12)).foregroundStyle(Color("Ink"))
      .padding(.horizontal, 12).frame(minHeight: 28)
      .background(Color("Card"), in: .capsule)
      .overlay(
        Capsule().strokeBorder(Color("Ink").opacity(configuration.isPressed ? 0.3 : 0.12))
      )
      .contentShape(.capsule)
  }
}

/// A pill for a write. Prominent is filled tide, for the action where focus is; the
/// rest are tinted so one card's action doesn't compete with another's.
struct ActionButtonStyle: ButtonStyle {
  let prominent: Bool
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13, weight: .semibold))
      .foregroundStyle(
        !enabled ? Color("SecondaryInk") : prominent ? Color("Canvas") : Color("TideText")
      )
      .padding(.horizontal, 14).frame(minHeight: 30)
      .background(
        !enabled
          ? Color("Ink").opacity(0.06)
          : prominent ? Color.accentColor : Color.accentColor.opacity(0.12), in: .capsule
      )
      .opacity(configuration.isPressed ? 0.8 : 1)
      .contentShape(.capsule)
  }
}
