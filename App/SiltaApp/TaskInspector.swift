import AppKit
import Foundation
import SiltaAppSupport
import SwiftUI

struct TaskInspector: View {
  @Bindable var model: AppModel
  @State private var task: AppTask?
  @State private var failure: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let task {
          HStack {
            CopyValue(value: task.ref, title: "Copy reference")
            Text(task.status.capitalized).font(.callout).foregroundStyle(.secondary)
          }
          Text(task.title).font(.title3.weight(.semibold)).textSelection(.enabled)
          Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            property("App", task.app)
            property("Priority", String(task.priority))
            property("Branch", task.branch)
            property("Claimed by", task.claimedBy)
            property("Claimed", task.claimedAt)
            property("Updated", task.updatedAt)
          }.font(.callout).textSelection(.enabled)
          if !task.description.isEmpty { Text(task.description).textSelection(.enabled) }
          if !task.plan.isEmpty {
            HStack {
              Text("Plan").font(.headline)
              Spacer()
              Text("Revision \(task.planRevision)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(task.steps.enumerated()), id: \.offset) { _, step in
              Label(step.title, systemImage: step.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.done ? .secondary : .primary)
            }
            DisclosureGroup("Full plan") { Text(task.plan).textSelection(.enabled) }
          }
          Text("Discussion").font(.headline)
          if task.comments.isEmpty { Text("No discussion yet").foregroundStyle(.secondary) }
          ForEach(task.comments, id: \.ref) { comment in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(comment.actor + " · " + comment.kind).font(.caption).foregroundStyle(
                  .secondary)
                Spacer()
                CopyValue(value: comment.ref, title: "Copy comment reference")
              }
              Text(comment.body).textSelection(.enabled)
            }
          }
          if let reader = model.reader, let workspace = model.workspace {
            let questions = questionCommands(reader, workspace: workspace, ref: task.ref)
            ForEach(questions, id: \.text) { command in CommandBlock(command: command) }
            if task.status == "review" {
              let reads = reader.commands(forReview: task, workspace: workspace)
              ForEach(reads, id: \.text) { command in CommandBlock(command: command) }
            }
          }
          if let path = task.worktree, path.hasPrefix("/"),
            FileManager.default.fileExists(atPath: path)
          {
            Button("Reveal worktree", systemImage: "folder") {
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
          }
        } else if let failure {
          ContentUnavailableView(
            "Task unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
        } else if model.selectedTask != nil {
          ProgressView("Loading task…")
        } else {
          ContentUnavailableView("Select a task", systemImage: "sidebar.right")
        }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }.task(id: selection) { await load() }
  }

  private var selection: String {
    [model.workspace ?? "", model.selectedTask ?? "", String(model.visibleData?.version ?? 0)]
      .joined(separator: ":")
  }

  private func load() async {
    task = nil
    failure = nil
    guard let reader = model.reader, let workspace = model.workspace, let ref = model.selectedTask
    else { return }
    do {
      let detail = try await Task.detached { try reader.task(ref, workspace: workspace) }.value
      try Task.checkCancellation()
      task = detail
    } catch {
      guard !Task.isCancelled else { return }
      failure = AppLoadFailure(error).message
    }
  }

  private func property(_ title: String, _ value: String?) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value ?? "—").fixedSize(horizontal: false, vertical: true)
    }
  }

  private func questionCommands(_ reader: AppReader, workspace: String, ref: String) -> [AppCommand]
  {
    guard let snapshot = model.visibleData?.snapshot else { return [] }
    return BoardContent(snapshot: snapshot, app: nil, search: "", proposals: false)
      .commands(for: ref, reader: reader, workspace: workspace)
  }
}
