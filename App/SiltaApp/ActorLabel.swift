import SwiftUI

struct ActorLabel: View {
  let actor: String

  var body: some View {
    let presentation = ActorPresentation(actor)
    Label {
      Text(presentation.name).font(.system(size: 12))
    } icon: {
      Image(systemName: presentation.symbol)
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 18, height: 18)
        .foregroundStyle(presentation.isCodex ? Color("Warning") : Color("TideText"))
        .background(
          (presentation.isCodex ? Color("Warning") : Color.accentColor).opacity(0.1),
          in: RoundedRectangle(cornerRadius: 5))
    }.help(actor).accessibilityLabel(presentation.name)
  }
}
