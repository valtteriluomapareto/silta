import SiltaAppSupport
import SwiftUI

/// The My work rows that write: accepting an answer, choosing and accepting proposals,
/// and unblocking a ready task.
extension MyWorkView {
  func answerRow(_ answer: MyWorkContent.Answer) -> some View {
    let ref = answer.item.ref ?? ""
    let target = model.target(ref)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        if let author = answer.item.author {
          ActorLabel(actor: author).labelStyle(.iconOnly).accessibilityHidden(true).frame(width: 22)
        }
        Text(answer.metadata).font(.system(size: 13)).foregroundStyle(Color("SecondaryInk"))
          .lineLimit(1).help(answer.metadata).frame(maxWidth: .infinity, alignment: .leading)
        Overline("Answer", color: Color("TideText"))
        CopyValue(value: ref, title: "Copy answer reference")
      }
      if let body = answer.item.body {
        Text(body).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
          .padding(.leading, 32).frame(maxWidth: 792, alignment: .leading)
      }
      if let failure = target.flatMap({ model.actions.failures[$0] }) {
        ActionFailureView(failure: failure).padding(.leading, 32)
      }
      HStack(spacing: 12) {
        Text("Accepting resolves your question.").font(.system(size: 12))
          .foregroundStyle(Color("SecondaryInk")).frame(maxWidth: .infinity, alignment: .leading)
        if let task = answer.item.task {
          Button("Open task") { model.inspect(task: task) }.buttonStyle(CompactActionStyle())
        }
        if let reader = model.reader, answer.canAccept(reader: reader, workspace: workspace) {
          let sending = target.map { model.actions.isSending($0) } ?? false
          Button(sending ? "Accepting…" : "Accept answer") {
            model.perform(.acceptAnswer(ref: ref), for: ref)
          }.buttonStyle(ActionButtonStyle(prominent: false)).disabled(sending)
        }
      }.padding(.leading, 32)
    }
  }

  func selection(_ ref: String) -> Binding<Bool> {
    Binding(
      get: { model.actions.selectedProposals.contains(ref) },
      set: { selected in
        if selected {
          model.actions.selectedProposals.insert(ref)
        } else {
          model.actions.selectedProposals.remove(ref)
        }
      })
  }

  func proposalFooter(_ rows: [MyWorkContent.Proposal]) -> some View {
    let visible = rows.map(\.ref)
    let chosen = visible.filter { model.actions.selectedProposals.contains($0) }.count
    let target = model.target(AppModel.proposalsTarget)
    let sending = target.map { model.actions.isSending($0) } ?? false
    let command = rows.first.flatMap {
      model.reader?.commands(for: $0.item, workspace: workspace).first
    }
    return VStack(alignment: .leading, spacing: 10) {
      if let failure = target.flatMap({ model.actions.failures[$0] }) {
        ActionFailureView(failure: failure)
      }
      if let reason = dropReason, chosen > 0 {
        HStack(spacing: 10) {
          TextField(
            "Why drop \(chosen == 1 ? "it" : "them")? Optional",
            text: Binding(get: { reason }, set: { dropReason = $0 })
          ).textFieldStyle(.roundedBorder).onSubmit { drop(visible) }
          Button("Cancel") { dropReason = nil }.buttonStyle(CompactActionStyle())
          Button(sending ? "Dropping…" : "Drop \(chosen)") { drop(visible) }
            .buttonStyle(ActionButtonStyle(prominent: false)).disabled(sending)
        }
      } else {
        HStack(spacing: 12) {
          Text(
            "\(chosen) of \(rows.count) selected · accepted tasks go to Todo; dropping asks for a "
              + "reason"
          )
          .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
          .frame(maxWidth: .infinity, alignment: .leading)
          if let command {
            CopyValue(value: command.text, title: "Copy command: " + command.title, pill: true)
          }
          Button(chosen == 0 ? "Drop…" : "Drop \(chosen)…") { dropReason = "" }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color("TideText"))
            .disabled(chosen == 0 || sending)
          Button(sending ? "Accepting…" : chosen == 0 ? "Accept" : "Accept \(chosen)") {
            model.acceptSelectedProposals(among: visible)
          }.buttonStyle(ActionButtonStyle(prominent: false)).disabled(chosen == 0 || sending)
        }
      }
    }.padding(.leading, 32).padding(.top, 4)
  }

  private func drop(_ visible: [String]) {
    let reason = dropReason ?? ""
    dropReason = nil
    model.dropSelectedProposals(among: visible, why: reason)
  }

  func unblockRow(_ ref: String) -> some View {
    let target = model.target(AppModel.unblockTarget(ref))
    let sending = target.map { model.actions.isSending($0) } ?? false
    return VStack(alignment: .leading, spacing: 10) {
      if let failure = target.flatMap({ model.actions.failures[$0] }) {
        ActionFailureView(failure: failure)
      }
      HStack(spacing: 12) {
        Text("Its blockers are done; unblocking returns it to Todo.").font(.system(size: 12))
          .foregroundStyle(Color("SecondaryInk")).frame(maxWidth: .infinity, alignment: .leading)
        Button(sending ? "Unblocking…" : "Unblock") {
          model.unblock(ref)
        }.buttonStyle(ActionButtonStyle(prominent: false)).disabled(sending)
      }
    }
  }
}
