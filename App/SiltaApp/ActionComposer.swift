import SiltaAppSupport
import SwiftUI

/// A text box that sends its draft as one write. The draft lives in the model, keyed
/// by target, so My work and the inspector share it and a failure never loses it.
struct ActionComposer: View {
  @Bindable var model: AppModel
  let target: ActionTarget
  let placeholder: String
  let sendTitle: String
  let command: AppCommand?
  var caption: String?
  let send: () -> Void
  @FocusState private var focused: Bool

  private var actions: ActionModel { model.actions }
  private var draft: Binding<String> {
    Binding(get: { actions.draft(target) }, set: { actions.setDraft($0, for: target) })
  }
  private var sending: Bool { actions.isSending(target) }
  private var empty: Bool {
    draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextEditor(text: draft).font(.system(size: 14)).scrollContentBackground(.hidden)
        .focused($focused).disabled(sending).accessibilityLabel(placeholder)
        .frame(minHeight: 52, maxHeight: 160).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .overlay(alignment: .topLeading) {
          if draft.wrappedValue.isEmpty {
            Text(placeholder).font(.system(size: 14)).foregroundStyle(Color("SecondaryInk"))
              .padding(.horizontal, 14).padding(.vertical, 8).allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .background(Color("Card"), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
          RoundedRectangle(cornerRadius: 12).strokeBorder(
            focused ? Color.accentColor : Color("Ink").opacity(0.14), lineWidth: 1)
        }
      if let failure = actions.failures[target] { ActionFailureView(failure: failure) }
      HStack(spacing: 12) {
        if let caption {
          Text(caption).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if let command {
          CopyValue(value: command.text, title: "Copy command: " + command.title, pill: true)
        }
        Button(action: send) {
          HStack(spacing: 8) {
            if sending { ProgressView().controlSize(.mini) }
            Text(sending ? "Sending…" : sendTitle)
            if !sending { Text("⌘↩").opacity(0.7).accessibilityHidden(true) }
          }
        }.buttonStyle(ActionButtonStyle(prominent: true)).disabled(empty || sending)
          .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
      }
    }
  }
}

/// Core's refusal in place: its code, its message, and the draft kept above it.
struct ActionFailureView: View {
  let failure: ActionFailure

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Circle().fill(Color("Danger")).frame(width: 7, height: 7).accessibilityHidden(true)
      Text(failure.message).font(.system(size: 13)).foregroundStyle(Color("Ink"))
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      if let code = failure.code {
        Text(code).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color("Danger"))
      }
      if let command = failure.commands.first {
        CopyValue(value: command, title: "Copy recovery command", pill: true)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .background(Color("Danger").opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color("Danger").opacity(0.25)))
    .accessibilityElement(children: .combine)
  }
}
