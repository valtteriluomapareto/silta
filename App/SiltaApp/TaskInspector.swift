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
            if let now = model.visibleData?.checkedAt,
              let banner = TaskPresentation.claimBanner(task, now: now)
            {
              ClaimBannerView(banner: banner, prompt: resumePrompt(task), worktree: task.worktree)
            }
            if let handoff = TaskFacts.handoff(task) {
              HandoffNote(text: handoff, prompt: resumePrompt(task))
            }
            if let waiting = TaskFacts.waiting(task) { WaitingSection(waiting: waiting) }
            properties(task)
            if !task.description.isEmpty { DocumentMarkdown(task.description) }
            if !task.acceptance.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Overline("Acceptance")
                DocumentMarkdown(task.acceptance)
              }
            }
            if let result = TaskFacts.result(task) { ResultSection(result: result) }
            if !task.plan.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Overline("Plan")
                  Spacer()
                  Text(TaskPresentation.progress(task.steps, revision: task.planRevision))
                    .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
                }
                let current = task.steps.firstIndex { !$0.done }
                ForEach(Array(task.steps.enumerated()), id: \.offset) { index, step in
                  HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(
                      systemName: step.done
                        ? "checkmark.circle.fill"
                        : index == current ? "smallcircle.filled.circle" : "circle"
                    )
                    .foregroundStyle(
                      Color(step.done || index == current ? "TideText" : "SecondaryInk")
                    )
                    .accessibilityLabel(
                      step.done ? "Complete" : index == current ? "Current step" : "Incomplete")
                    Text(step.title).fontWeight(index == current ? .semibold : .regular)
                      .foregroundStyle(Color(step.done ? "SecondaryInk" : "Ink"))
                  }.font(.system(size: 13))
                }
                DisclosureGroup("Full plan") { Text(task.plan).textSelection(.enabled) }
                  .font(.system(size: 12))
              }
            }
            let subtasks = TaskFacts.subtasks(task)
            if !subtasks.isEmpty {
              ReferenceList(
                title: "Subtasks",
                rows: subtasks.map { ReferenceList.Row(ref: $0.ref, text: $0.title) })
            }
            let links = TaskFacts.otherLinks(task)
            if !links.isEmpty {
              ReferenceList(
                title: "Links",
                rows: links.map {
                  ReferenceList.Row(
                    ref: $0.rel, text: $0.target,
                    url: $0.target.hasPrefix("url:")
                      ? URL(string: String($0.target.dropFirst("url:".count))) : nil)
                })
            }
            DiscussionView(model: model, task: task).id(task.ref)
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
          maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
      }.seaPane()
    }.foregroundStyle(Color("Ink"))
      .task(id: selection) { await model.loadTaskDetail() }
  }

  @ViewBuilder private func statusDot(_ status: String) -> some View {
    if status == "todo" {
      Circle().strokeBorder(Color("SecondaryInk"), lineWidth: 1.5).frame(width: 8, height: 8)
    } else {
      StatusDot(
        color: Color(status == "doing" ? "TideText" : status == "done" ? "Success" : "Warning")
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

  private func resumePrompt(_ task: AppTask) -> String? {
    guard let reader = model.reader, let workspace = model.workspace else { return nil }
    let name = model.visibleData?.workspaces.first { $0.slug == workspace }?.name ?? workspace
    return reader.agentPrompt(task: task.ref, workspace: workspace, name: name)
  }

  private func properties(_ task: AppTask) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
      property("App", task.app)
      property("Priority", String(task.priority))
      property("Branch", task.branch, monospaced: true)
      property("Claimed by", TaskPresentation.claimant(task.claimedBy))
      property("Claimed", age(task.claimedAt))
      property("Updated", age(task.updatedAt))
      if task.status == "done" || task.status == "dropped" {
        property(task.status == "done" ? "Done" : "Dropped", age(task.closedAt))
      }
      if let commit = TaskFacts.commit(task) { property("Commit", commit, monospaced: true) }
      ForEach(TaskFacts.pullRequests(task), id: \.url) { pull in
        GridRow {
          Text("Pull request").foregroundStyle(Color("SecondaryInk"))
          if let url = URL(string: pull.url) {
            Link(pull.title, destination: url).foregroundStyle(Color("TideText"))
          } else {
            Text(pull.title)
          }
        }
      }
      if task.doneDirty == true {
        GridRow {
          Text("Worktree").foregroundStyle(Color("SecondaryInk"))
          Text("Had uncommitted changes when done").foregroundStyle(Color("Warning"))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let parent = TaskFacts.parent(task) {
        property(
          "Parent", [parent.ref, parent.title].filter { !$0.isEmpty }.joined(separator: " "))
      }
      if let external = task.externalRef { property("Tracker", external, monospaced: true) }
      property("Created", TaskFacts.created(task))
    }.font(.system(size: 12)).textSelection(.enabled)
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color("Ink").opacity(0.03), in: .rect(cornerRadius: 12))
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
      let content = BoardContent(snapshot: snapshot, apps: [], filter: BoardFilter(), search: "")
      TaskComposer(
        model: model, task: task.ref,
        question: content.newestQuestion(for: task.ref, reader: reader, workspace: workspace)
      ).id(task.ref)
      if task.status == "review" {
        ForEach(reader.commands(forReview: task, workspace: workspace), id: \.text) {
          CommandBlock(command: $0)
        }
      }
    }
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

/// The inspector's box: answer the newest open question to the human, or comment.
private struct TaskComposer: View {
  @Bindable var model: AppModel
  let task: String
  let question: BoardContent.Answer?
  @State private var commenting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let question, let ref = question.question {
        Picker("Reply as", selection: $commenting) {
          Text(question.actor.map { "Answer " + ActorPresentation($0).name } ?? "Answer")
            .tag(false)
          Text("Comment").tag(true)
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
        if !commenting, let target = model.target(ref) {
          ActionComposer(
            model: model, target: target, placeholder: "Your answer to \(ref)",
            sendTitle: "Send answer", command: question.command
          ) { model.answer(question: ref, task: task) }
        } else {
          comment
        }
      } else {
        Overline("Comment on \(task)")
        comment
      }
    }
  }

  @ViewBuilder private var comment: some View {
    if let target = model.target(task) {
      ActionComposer(
        model: model, target: target, placeholder: "Add a comment", sendTitle: "Comment",
        command: nil
      ) { model.comment(task: task) }
    }
  }
}
