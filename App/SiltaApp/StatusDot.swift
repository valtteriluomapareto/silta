import SwiftUI

struct StatusDot: View {
  let color: Color
  var body: some View {
    Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
  }
}
