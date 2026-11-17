import AppKit
import Foundation
import SwiftUI

struct CopyValue: View {
  let value: String
  let title: String
  var compact = false
  @State private var copied = false

  var body: some View {
    Button {
      copy()
    } label: {
      HStack(spacing: 5) {
        if !compact { Text(copied ? "Copied" : value).font(.system(size: 12, design: .monospaced)) }
        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
      }
      .padding(.horizontal, compact ? 7 : 8).padding(.vertical, compact ? 7 : 3)
      .foregroundStyle(copied ? Color.green : compact ? Color("Ink") : Color("TideText"))
      .background(
        compact ? Color.clear : Color.accentColor.opacity(0.1),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain)
      .help(copied ? "Copied" : title).accessibilityLabel(
        (copied ? "Copied" : title) + ": " + value
      )
      .contextMenu { Button(title) { copy() } }
      .onCopyCommand { [NSItemProvider(object: value as NSString)] }
      .onChange(of: value) { copied = false }
      .task(id: copied) {
        guard copied else { return }
        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
        copied = false
      }
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    copied = NSPasteboard.general.setString(value, forType: .string)
  }
}
