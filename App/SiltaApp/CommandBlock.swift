import SiltaAppSupport
import SwiftUI

struct CommandBlock: View {
  let command: AppCommand
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(command.title).font(.caption).foregroundStyle(.secondary)
        Spacer()
        CopyValue(value: command.text, title: "Copy command", compact: true)
      }
      Text(command.text).font(.system(.callout, design: .monospaced))
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }
}
