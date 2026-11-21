import SiltaAppSupport
import SwiftUI

/// A task waiting for the human's review: mark it done with a nonblank result, request
/// changes from its submitter, or drop it. Each draft clears only when its write succeeds.
struct ReviewCard: View {
  enum Mode: String, CaseIterable {
    case done = "Mark done"
    case changes = "Request changes"
    case drop = "Drop"
  }

  @Bindable var model: AppModel
  let review: MyWorkContent.Review
  @State private var mode = Mode.done
  @FocusState private var focused: Bool

  private var ref: String { review.task.ref }
  /// The agent session that submitted the task; a human submitter isn't asked.
  private var submitter: String? {
    review.task.submission?.actor.hasPrefix("agent:") == true ? review.task.submission?.actor : nil
  }
  private var target: ActionTarget? { model.target(AppModel.followUpTarget(ref)) }
  private var changesTarget: ActionTarget? { model.target(AppModel.changesTarget(ref)) }
  private var sending: Bool {
    [target, changesTarget].compactMap { $0 }.contains { model.actions.isSending($0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        StatusDot(color: Color("Warning")).frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text("Review " + review.task.title).font(.system(size: 15, weight: .semibold))
            .lineLimit(2).help(review.task.title)
          Text(review.metadata).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
        }.frame(maxWidth: .infinity, alignment: .leading)
        ForEach(TaskFacts.pullRequests(review.task), id: \.url) { pull in
          if let url = URL(string: pull.url) {
            Link("Open " + pull.title, destination: url).font(.system(size: 12))
              .foregroundStyle(Color("TideText"))
          }
        }
        CopyValue(value: ref, title: "Copy task reference")
      }
      if model.writer != nil {
        Picker("Action", selection: $mode) {
          ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.leading, 32)
          .disabled(sending)
        editor.padding(.leading, 32)
        if let failure = modeTarget.flatMap({ model.actions.failures[$0] }) {
          ActionFailureView(failure: failure).padding(.leading, 32)
          if failure.code == "gate", mode == .done, let reader = model.reader,
            let workspace = model.workspace
          {
            Text("The workspace's review gate needs a human approval the app can't record yet.")
              .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk")).padding(.leading, 32)
            CommandBlock(command: reader.forceDoneCommand(task: review.task, workspace: workspace))
              .padding(.leading, 32)
          }
        }
        footer.padding(.leading, 32)
      } else if let command = model.reader?.commands(
        forReview: review.task, workspace: model.workspace ?? ""
      ).first {
        CommandBlock(command: command).padding(.leading, 32)
      }
    }
  }

  /// The write target of the mode on screen, whose failure the card shows.
  private var modeTarget: ActionTarget? { mode == .changes ? changesTarget : target }

  @ViewBuilder private var editor: some View {
    switch mode {
    case .done:
      VStack(alignment: .leading, spacing: 6) {
        draftEditor(AppModel.doneResultTarget(ref), placeholder: "Result, ending with Friction:")
        if review.task.app != nil {
          draftField(AppModel.doneSHATarget(ref), placeholder: "Merge commit (optional)")
            .font(.system(size: 12, design: .monospaced)).frame(maxWidth: 260)
        }
      }
    case .changes:
      draftEditor(AppModel.changesTarget(ref), placeholder: "What should change?")
    case .drop:
      draftField(AppModel.dropTaskReasonTarget(ref), placeholder: "Why drop it? Optional")
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text(caption).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Open task") { model.inspect(task: ref) }.buttonStyle(CompactActionStyle())
      Button(sending ? "Sending…" : mode.rawValue) { send() }
        .buttonStyle(ActionButtonStyle(prominent: mode == .done))
        .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(sending || !ready)
    }
  }

  private var caption: String {
    switch mode {
    case .done:
      review.task.app == nil
        ? "The result can't be empty." : ReviewCard.doneCaption
    case .changes:
      submitter.map { "Waits in \(ActorPresentation($0).name)'s brief until it answers." }
        ?? "No agent submission is recorded to ask."
    case .drop: "Dropping closes the task without a commit."
    }
  }

  static let doneCaption = "The result can't be empty; leave the commit empty to record none."

  private var ready: Bool {
    switch mode {
    case .done: !draft(AppModel.doneResultTarget(ref)).isEmpty
    case .changes: submitter != nil && !draft(AppModel.changesTarget(ref)).isEmpty
    case .drop: true
    }
  }

  private func draft(_ ref: String) -> String {
    model.target(ref).map { model.actions.draft($0) }?.trimmingCharacters(
      in: .whitespacesAndNewlines) ?? ""
  }

  private func send() {
    switch mode {
    case .done: model.markDone(ref)
    case .changes: if let submitter { model.requestChanges(ref, from: submitter) }
    case .drop: model.dropTask(ref)
    }
  }

  private func binding(_ ref: String) -> Binding<String> {
    Binding(
      get: { model.target(ref).map { model.actions.draft($0) } ?? "" },
      set: { text in if let target = model.target(ref) { model.actions.setDraft(text, for: target) }
      })
  }

  private func draftEditor(_ ref: String, placeholder: String) -> some View {
    TextField(placeholder, text: binding(ref), axis: .vertical).lineLimit(3...8)
      .textFieldStyle(.roundedBorder).disabled(sending).focused($focused)
  }

  private func draftField(_ ref: String, placeholder: String) -> some View {
    TextField(placeholder, text: binding(ref)).textFieldStyle(.roundedBorder).disabled(sending)
      .focused($focused)
  }
}
