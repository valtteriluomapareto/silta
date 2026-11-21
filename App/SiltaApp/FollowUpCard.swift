import SiltaAppSupport
import SwiftUI

/// A blocked task whose follow-up came due, or whose blocker was dropped: snooze it,
/// unblock it anyway after a confirm step that names the open blockers, open it, or drop it.
struct FollowUpCard: View {
  @Bindable var model: AppModel
  let followUp: FollowUp
  @State private var confirmingUnblock = false
  @State private var askingWhy = false

  private var ref: String { followUp.task.ref }
  private var target: ActionTarget? { model.target(AppModel.followUpTarget(ref)) }
  private var sending: Bool { target.map { model.actions.isSending($0) } ?? false }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        StatusDot(color: Color("Warning")).frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(followUp.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
          Text(followUp.subtitle).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
        }.frame(maxWidth: .infinity, alignment: .leading)
        Overline(followUp.replan ? "Re-plan" : "Due", color: Color("Warning"))
        CopyValue(value: ref, title: "Copy task reference")
      }
      if !followUp.task.on.isEmpty || followUp.task.why != nil {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if !followUp.task.on.isEmpty {
            Text(followUp.task.on.joined(separator: ", "))
              .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color("TideText"))
          }
          if let why = followUp.task.why { Text(why).font(.system(size: 13)) }
        }.padding(.leading, 32).textSelection(.enabled)
      }
      if let failure = target.flatMap({ model.actions.failures[$0] }) {
        ActionFailureView(failure: failure).padding(.leading, 32)
      }
      footer.padding(.leading, 32)
    }
  }

  @ViewBuilder private var footer: some View {
    if confirmingUnblock {
      HStack(spacing: 10) {
        Text(followUp.unblockWarning).font(.system(size: 12))
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Cancel") { confirmingUnblock = false }.buttonStyle(CompactActionStyle())
          .keyboardShortcut(.cancelAction)
        Button(sending ? "Unblocking…" : "Unblock") {
          Task {
            await model.unblockAnyway(ref)?.value
            if let target, model.actions.failures[target] == nil { confirmingUnblock = false }
          }
        }.buttonStyle(ActionButtonStyle(prominent: false)).disabled(sending)
      }
    } else if askingWhy, let reason = model.target(AppModel.dropTaskReasonTarget(ref)) {
      HStack(spacing: 10) {
        TextField(
          "Why drop it? Optional",
          text: Binding(
            get: { model.actions.draft(reason) }, set: { model.actions.setDraft($0, for: reason) })
        ).textFieldStyle(.roundedBorder).disabled(sending).onSubmit { if !sending { drop() } }
        Button("Cancel") { askingWhy = false }.buttonStyle(CompactActionStyle())
          .keyboardShortcut(.cancelAction).disabled(sending)
        Button(sending ? "Dropping…" : "Drop") { drop() }
          .buttonStyle(ActionButtonStyle(prominent: false)).disabled(sending)
      }
    } else {
      HStack(spacing: 12) {
        Spacer()
        Button("Drop…") { askingWhy = true }.buttonStyle(CompactActionStyle()).disabled(sending)
        Button("Unblock anyway…") { confirmingUnblock = true }.buttonStyle(CompactActionStyle())
          .disabled(sending)
        Button("Open task") { model.inspect(task: ref) }.buttonStyle(CompactActionStyle())
        if !followUp.replan {
          Menu("Snooze 7 days") {
            ForEach([3, 7, 14, 30], id: \.self) { days in
              Button("Snooze \(days) days") { model.snooze(ref, days: days) }
            }
          } primaryAction: {
            model.snooze(ref, days: 7)
          }.menuStyle(.borderedButton).fixedSize().disabled(sending)
        }
      }
    }
  }

  private func drop() {
    Task {
      await model.dropTask(ref)?.value
      if let target, model.actions.failures[target] == nil { askingWhy = false }
    }
  }
}
