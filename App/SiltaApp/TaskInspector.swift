import AppKit
import Foundation
import SiltaAppSupport
import SwiftUI

struct TaskInspector: View {
  @Bindable var model: AppModel
  private var detail: TaskDetailModel { model.taskDetail }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let task = detail.value {
            HStack(spacing: 8) {
              CopyValue(value: task.ref, title: "Copy reference")
              HStack(spacing: 5) {
                statusDot(task.status)
                Text(task.status.capitalized).font(.system(size: 11, weight: .semibold))
              }.padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color("Card"), in: .capsule)
                .overlay(Capsule().strokeBorder(Color("Ink").opacity(0.08)))
              Spacer(minLength: 4)
              if let app = task.app {
                Text(app).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
              }
            }
            Text(task.title).font(.system(size: 20, weight: .bold)).tracking(-0.2)
              .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              property("App", task.app)
              property("Priority", String(task.priority))
              property("Branch", task.branch, monospaced: true)
              property("Claimed by", TaskPresentation.claimant(task.claimedBy))
              property("Claimed", age(task.claimedAt))
              property("Updated", age(task.updatedAt))
            }.font(.system(size: 12)).textSelection(.enabled)
              .padding(12).frame(maxWidth: .infinity, alignment: .leading)
              .background(Color("Ink").opacity(0.03), in: .rect(cornerRadius: 12))
            if !task.description.isEmpty { DocumentMarkdown(task.description) }
            if !task.plan.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Overline("Plan")
                  Spacer()
                  Text(TaskPresentation.progress(task.steps, revision: task.planRevision))
                    .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
                }
                ForEach(Array(task.steps.enumerated()), id: \.offset) { _, step in
                  HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                      .foregroundStyle(Color(step.done ? "TideText" : "SecondaryInk"))
                      .accessibilityLabel(step.done ? "Complete" : "Incomplete")
                    Text(step.title).foregroundStyle(Color(step.done ? "SecondaryInk" : "Ink"))
                  }.font(.system(size: 13))
                }
                DisclosureGroup("Full plan") { Text(task.plan).textSelection(.enabled) }
                  .font(.system(size: 12))
              }
            }
            VStack(alignment: .leading, spacing: 10) {
              Overline("Discussion")
              if task.comments.isEmpty {
                Text("No discussion yet").font(.system(size: 13)).foregroundStyle(
                  Color("SecondaryInk"))
              }
              ForEach(task.comments, id: \.ref) { comment in
                VStack(alignment: .leading, spacing: 3) {
                  HStack(alignment: .firstTextBaseline) {
                    Text(
                      [ActorPresentation(comment.actor).name, comment.kind, age(comment.createdAt)]
                        .compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
                    Spacer(minLength: 4)
                    CopyValue(value: comment.ref, title: "Copy comment reference", compact: true)
                  }
                  Text(comment.body).font(.system(size: 13)).textSelection(.enabled)
                }.padding(.leading, 12)
                  .overlay(alignment: .leading) {
                    Rectangle().fill(commentColor(comment.actor)).frame(width: 2)
                  }
              }
            }
            actions(task)
            if let failure = detail.failure {
              Label(failure, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
              Button("Retry") { Task { await model.loadTaskDetail() } }
            }
            Spacer(minLength: 12)
            worktreeButton(task)
          } else if let failure = detail.failure {
            ContentUnavailableView {
              Label("Task unavailable", systemImage: "exclamationmark.triangle")
            } description: {
              Text(failure)
            } actions: {
              Button("Retry") { Task { await model.loadTaskDetail() } }
            }
          } else if model.boardSelection?.taskRef != nil {
            ProgressView("Loading task…")
          } else {
            ContentUnavailableView("Select a task", systemImage: "sidebar.right")
          }
        }.padding(18).frame(
          maxWidth: .infinity, minHeight: geometry.size.height - 20, alignment: .topLeading)
      }.seaPane().padding(10)
    }.foregroundStyle(Color("Ink"))
      .background { ShoreBackground() }
      .task(id: selection) { await model.loadTaskDetail() }
  }

  @ViewBuilder private func statusDot(_ status: String) -> some View {
    if status == "todo" {
      Circle().strokeBorder(Color("SecondaryInk"), lineWidth: 1.5).frame(width: 8, height: 8)
    } else {
      StatusDot(
        color: Color(status == "doing" ? "TideText" : status == "done" ? "DiffAddition" : "Warning")
      )
    }
  }

  private func age(_ value: String?) -> String? {
    guard let now = model.visibleData?.checkedAt else { return value }
    return RelativeAge.text(value, now: now) ?? value
  }

  private var selection: String {
    [
      model.workspace ?? "", model.boardSelection?.taskRef ?? "",
      String(model.visibleData?.version ?? 0),
    ]
    .joined(separator: ":")
  }

  private func property(_ title: String, _ value: String?, monospaced: Bool = false) -> some View {
    GridRow {
      Text(title).foregroundStyle(Color("SecondaryInk"))
      Text(value ?? "—").font(.system(size: 12, design: monospaced ? .monospaced : .default))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private func actions(_ task: AppTask) -> some View {
    if let reader = model.reader, let workspace = model.workspace,
      let snapshot = model.visibleData?.snapshot
    {
      let content = BoardContent(snapshot: snapshot, app: nil, search: "", proposals: false)
      ForEach(content.answers(for: task.ref, reader: reader, workspace: workspace)) { answer in
        VStack(alignment: .leading, spacing: 8) {
          Overline(
            answer.actor.map { "Answer " + ActorPresentation($0).name } ?? "Answer question",
            color: Color("TideText"))
          CommandBlock(command: answer.command)
        }.padding(12).background(Color("AccentColor").opacity(0.06), in: .rect(cornerRadius: 12))
      }
      if task.status == "review" {
        ForEach(reader.commands(forReview: task, workspace: workspace), id: \.text) {
          CommandBlock(command: $0)
        }
      }
    }
  }

  private func commentColor(_ actor: String) -> Color {
    let presentation = ActorPresentation(actor)
    return presentation.isCodex
      ? Color("Warning") : actor.hasPrefix("agent:") ? Color("AccentColor") : Color("SecondaryInk")
  }

  @ViewBuilder private func worktreeButton(_ task: AppTask) -> some View {
    let path = task.worktree
    let available =
      path.map { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) } ?? false
    Button("Reveal worktree", systemImage: "folder") {
      if let path { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    }.buttonStyle(CompactActionStyle()).disabled(!available).opacity(available ? 1 : 0.45)
      .help(available ? "Reveal the recorded worktree" : "No existing worktree is recorded")
  }
}
