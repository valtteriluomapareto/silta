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
      CopyValue(value: command.text, title: "Copy command: " + command.title, pill: true)
    }
    .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
    .frame(minHeight: 38)
    .background(Color("CommandSurface"), in: RoundedRectangle(cornerRadius: 12))
    .help(command.title)
  }

  private var commandText: some View {
    var value = AttributedString()
    for (index, part) in CommandPresentation.parts(command.text).enumerated() {
      var span = AttributedString(part.text)
      span.foregroundColor =
        part.warning
        ? Color("Warning")
        : index == 0 && part.text.hasPrefix("SILTA_HOME=") ? Color("SecondaryInk") : Color("Ink")
      value.append(span)
    }
    return Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
  }
}
