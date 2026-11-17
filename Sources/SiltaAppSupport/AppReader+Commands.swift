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

  /// Offers read-only detail for a task waiting for review.
  public func commands(forReview task: AppTask, workspace: String) -> [AppCommand] {
    [taskCommand(task.ref, workspace: workspace)]
  }

  /// Reads the full human inbox beyond the default cap.
  public func inboxCommand(workspace: String) -> AppCommand {
    command("Read full inbox", suffix: "inbox --for me --all", workspace: workspace)
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
      read, command("Accept revisions", suffix: "doc triage --accept REFS", workspace: workspace),
      command("Read triage help", suffix: "doc triage --help", workspace: workspace),
    ]
  }

  private func taskCommand(_ ref: String, workspace: String) -> AppCommand {
    command(
      "Read task", suffix: "task show " + shellWord(ref) + " --timeline", workspace: workspace)
  }

  private func command(_ title: String, suffix: String, workspace: String) -> AppCommand {
    let prefix =
      environment.home.url == defaultHome
      ? "" : "SILTA_HOME=" + shellWord(environment.home.url.path) + " "
    return AppCommand(
      title: title, text: prefix + "silta --ws " + shellWord(workspace) + " " + suffix)
  }
}
