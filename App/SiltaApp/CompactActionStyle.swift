import SwiftUI

struct CompactActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12)).foregroundStyle(Color("Ink"))
      .padding(.horizontal, 10).frame(height: 24)
      .background(Color("Canvas"), in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(Color("Ink").opacity(configuration.isPressed ? 0.3 : 0.14))
      )
      .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
  }
}
