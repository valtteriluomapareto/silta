import Foundation
import SiltaCore

extension AppReader {
  /// Offers safe templates for an inbox entry without executing them.
  public func commands(for item: AppAttention, workspace: String) -> [AppCommand] {
    let taskGroups = ["proposal", "due", "ready", "replan", "promoted"]
    let refs = taskGroups.contains(item.kind) ? item.refs : item.task.map { [$0] } ?? []
    let reads = refs.map { taskCommand($0, workspace: workspace) }
    if item.kind == "question", let task = item.task, let ref = item.ref {
      return [
        command(
          "Answer question",
          suffix: "comment " + shellWord(task) + " --kind answer --reply-to " + shellWord(ref)
            + " -m \"\"", workspace: workspace)
      ] + reads
    }
    if item.kind == "proposal" {
      return [
        command("Accept proposals", suffix: "task triage --accept REFS", workspace: workspace),
        command("Read triage help", suffix: "task triage --help", workspace: workspace),
      ] + reads
    }
    if item.kind == "answer", let ref = item.ref {
      let expected = "silta --ws " + shellWord(workspace) + " comment accept " + shellWord(ref)
      if item.commands.contains(expected) {
        return [
          command(
            "Accept answer", suffix: "comment accept " + shellWord(ref),
            workspace: workspace)
        ] + reads
      }
    }
    return reads
  }

  /// Completes a reviewed task past an unmet review gate, for the human to run in a
  /// terminal; the empty result fails safe until they write one.
  public func forceDoneCommand(task ref: String, workspace: String) -> AppCommand {
    command(
      "Mark done past the review gate",
      suffix: "task done " + shellWord(ref) + " --force -m \"\"", workspace: workspace)
  }

  /// Offers read-only detail for a task waiting for review.
  public func commands(forReview task: AppTask, workspace: String) -> [AppCommand] {
    [readCommand(task: task.ref, workspace: workspace)]
  }

  /// Reads one task with its timeline.
  public func readCommand(task ref: String, workspace: String) -> AppCommand {
    taskCommand(ref, workspace: workspace)
  }

  /// What the human pastes into an agent session to start or resume a task. The app only
  /// copies it and never launches an agent (D4). Like every copied command it pins the data
  /// home, so an agent with another `SILTA_HOME` still acts on the human's store.
  public func agentPrompt(task ref: String, workspace: String, name: String) -> String {
    let silta = command("", suffix: "", workspace: workspace).text.trimmingCharacters(
      in: .whitespaces)
    let label = name.filter { $0 != "`" && !$0.isNewline }
    return "Work on \(ref) in \(label). Read it with `\(silta) task show \(shellWord(ref))`, "
      + "then claim it with `\(silta) task start \(shellWord(ref))`."
  }

  /// Reads the full human inbox beyond the default cap.
  public func inboxCommand(workspace: String) -> AppCommand {
    command("Read full inbox", suffix: "inbox --for me --all", workspace: workspace)
  }

  /// Offers one unfilled document-proposal triage command without choosing revisions.
  public func documentTriageCommand(workspace: String) -> AppCommand {
    command("Accept revisions", suffix: "doc triage --accept REFS", workspace: workspace)
  }

  /// Offers a scoped document read and safe, unfilled proposal-triage templates.
  public func commands(forDocument document: AppDocument, workspace: String, view: AppDocumentView)
    -> [AppCommand]
  {
    let flags = view == .changes ? " --diff" : view == .comments ? " --comments" : ""
    let read = command(
      "Read document", suffix: "doc show " + shellWord(document.ref) + flags, workspace: workspace)
    guard document.state == "proposed", view == .changes else { return [read] }
    return [
      read, documentTriageCommand(workspace: workspace),
      command("Read triage help", suffix: "doc triage --help", workspace: workspace),
    ]
  }

  private func taskCommand(_ ref: String, workspace: String) -> AppCommand {
    command(
      "Read task", suffix: "task show " + shellWord(ref) + " --timeline", workspace: workspace)
  }

  private func command(_ title: String, suffix: String, workspace: String) -> AppCommand {
    let prefix =
      environment.home.isDefault
      ? "SILTA_HOME=~/.silta " : "SILTA_HOME=" + shellWord(environment.home.url.path) + " "
    return AppCommand(
      title: title, text: prefix + "silta --ws " + shellWord(workspace) + " " + suffix)
  }
}
