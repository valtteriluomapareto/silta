import AppKit
import SwiftUI

struct ToolbarSearchField: NSViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
  let prompt: String

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.delegate = context.coordinator
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.setAccessibilityLabel(prompt)
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    field.placeholderString = prompt
    field.setAccessibilityLabel(prompt)
    if focused, field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: ToolbarSearchField
    init(_ parent: ToolbarSearchField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
    }

    func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
    func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
  }
}
