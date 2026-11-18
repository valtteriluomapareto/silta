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
