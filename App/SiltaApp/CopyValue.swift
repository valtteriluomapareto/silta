import AppKit
import Foundation
import SwiftUI

struct CopyValue: View {
  let value: String
  let title: String
  var compact = false
  var warning = false
  /// Shows a "Copy" pill instead of the value, for command blocks.
  var pill = false
  private var tint: Color { Color(warning ? "Warning" : "TideText") }
  @State private var copied = false

  var body: some View {
    Button {
      copy()
    } label: {
      HStack(spacing: 5) {
        if pill {
          Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
            .foregroundStyle(copied ? Color("Success") : Color("Ink"))
          Text(copied ? "Copied" : "Copy").font(.system(size: 12))
        } else {
          if !compact {
            Text(copied ? "Copied" : value).font(.system(size: 11, design: .monospaced))
          }
          Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
            .foregroundStyle(copied ? Color("Success") : compact ? Color("Ink") : tint)
        }
      }
      .padding(.horizontal, pill ? 10 : compact ? 7 : 9).padding(
        .vertical, pill ? 0 : compact ? 7 : 4
      )
      .frame(minHeight: pill ? 26 : nil)
      .foregroundStyle(copied || compact || pill ? Color("Ink") : tint)
      .background {
        if pill {
          Capsule().fill(Color("Card")).overlay(Capsule().strokeBorder(Color("Ink").opacity(0.1)))
        } else if !compact {
          Capsule().fill(tint.opacity(0.1))
        }
      }
      .contentShape(.capsule)
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
