import SiltaAppSupport
import SwiftUI

struct CommandBlock: View {
  let command: AppCommand

  var body: some View {
    HStack(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        commandText.fixedSize()
        commandText.fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      CopyValue(value: command.text, title: "Copy command", compact: true)
    }
    .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
    .frame(minHeight: 34)
    .background(Color("CommandSurface"), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07)))
    .help(command.title)
  }

  private var commandText: some View {
    var value = AttributedString()
    for part in CommandPresentation.parts(command.text) {
      var span = AttributedString(part.text)
      span.foregroundColor = part.warning ? Color("Warning") : Color("Ink")
      value.append(span)
    }
    return Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
  }
}
