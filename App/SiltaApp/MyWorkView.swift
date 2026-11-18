import Foundation
import SiltaAppSupport
import SwiftUI

struct MyWorkView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      if let data = model.visibleData, let snapshot = data.snapshot {
        let content = MyWorkContent(snapshot: snapshot, search: model.search, now: data.checkedAt)
        LazyVStack(alignment: .leading, spacing: 10) {
          if snapshot.work.waitingCount == 0 && model.search.isEmpty {
            ContentUnavailableView(
              "Nothing waits on you", systemImage: "tray",
              description: Text(
                "\(snapshot.board.doing.filter { $0.claimedBy != nil }.count) tasks claimed."))
          } else if !content.hasMatches && !model.search.isEmpty {
            ContentUnavailableView(
              "No matches", systemImage: "magnifyingglass",
              description: Text("Try another reference or search term."))
          }
          ForEach(content.questions) { question in
            questionRow(question).padding(.horizontal, 22).padding(.vertical, 20)
              .seaCard()
          }
          ForEach(content.answers) { answer in
            answerRow(answer).padding(.horizontal, 22).padding(.vertical, 18).seaCard()
          }
          ForEach(content.reviews) { review in
            reviewRow(review).padding(.horizontal, 22).padding(.vertical, 16).seaPane()
          }
          if !content.documents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              sectionHeader(
                "Doc proposals", count: content.documents.count, color: Color("Warning"))
              ForEach(content.documents) { row in
                HStack(spacing: 10) {
                  proposalTitle(row).frame(maxWidth: .infinity, alignment: .leading)
                  Button("Show changes") { model.openDocument(row.ref) }
                    .buttonStyle(CompactActionStyle())
                  CopyValue(value: row.ref, title: "Copy document reference", warning: true)
                    .lineLimit(1).truncationMode(.middle).frame(width: 196, alignment: .trailing)
                }.padding(.leading, 32).frame(minHeight: 30)
              }
              if let command = model.reader?.documentTriageCommand(workspace: workspace) {
                CommandBlock(command: command).padding(.leading, 32)
              }
            }.padding(.horizontal, 22).padding(.vertical, 16).seaPane()
          }
          if !content.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              sectionHeader("Task proposals", count: content.tasks.count, color: .secondary)
              ForEach(content.tasks) { row in
                HStack(spacing: 10) {
                  Toggle(isOn: selection(row.ref)) { proposalTitle(row) }
                    .toggleStyle(.checkbox).accessibilityLabel("Accept \(row.ref)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                  CopyValue(value: row.ref, title: "Copy task reference", warning: true)
                    .fixedSize()
                }.padding(.leading, 32).frame(minHeight: 28)
              }
              proposalFooter(content.tasks)
            }.padding(.horizontal, 22).padding(.vertical, 16).seaPane()
          }
          ForEach(content.other, id: \.stableID) { item in
            otherAttention(item).padding(.horizontal, 22).padding(.vertical, 16).seaPane()
          }
          if content.remaining > 0 {
            Text("\(content.remaining) more waiting items").font(
              .system(size: 14, weight: .semibold))
            if let command = model.reader?.inboxCommand(workspace: workspace) {
              CommandBlock(command: command)
            }
          }
        }.padding(.bottom, 24)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }.foregroundStyle(Color("Ink"))
  }

  private var workspace: String { model.workspace ?? "" }

  private func questionRow(_ question: MyWorkContent.Question) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        if let author = question.item.author {
          ActorLabel(actor: author).labelStyle(.iconOnly).accessibilityHidden(true).frame(width: 22)
        }
        Text(question.metadata).font(.system(size: 13)).foregroundStyle(Color("SecondaryInk"))
          .lineLimit(1).help(question.metadata)
          .frame(maxWidth: .infinity, alignment: .leading)
        Overline("Question", color: Color("TideText"))
        if let ref = question.ref { CopyValue(value: ref, title: "Copy task reference") }
      }
      Text(question.headline).font(.system(size: 18, weight: .semibold)).lineLimit(3)
        .lineSpacing(3).help(question.headline).textSelection(.enabled).padding(.leading, 32)
        .frame(maxWidth: 760, alignment: .leading)
      if let ref = question.item.ref, let task = question.item.task,
        let target = model.target(ref)
      {
        ActionComposer(
          model: model, target: target, placeholder: "Your answer to \(ref)",
          sendTitle: "Send answer",
          command: model.reader.flatMap { question.command(reader: $0, workspace: workspace) },
          caption: "Replies to \(ref) as you"
        ) { model.answer(question: ref, task: task) }.padding(.leading, 32)
      }
    }
  }

  private func answerRow(_ answer: MyWorkContent.Answer) -> some View {
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

  private func selection(_ ref: String) -> Binding<Bool> {
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

  private func proposalFooter(_ rows: [MyWorkContent.Proposal]) -> some View {
    let chosen = rows.filter { model.actions.selectedProposals.contains($0.ref) }.count
    let target = model.target(AppModel.proposalsTarget)
    let sending = target.map { model.actions.isSending($0) } ?? false
    let command = rows.first.flatMap {
      model.reader?.commands(for: $0.item, workspace: workspace).first
    }
    return VStack(alignment: .leading, spacing: 10) {
      if let failure = target.flatMap({ model.actions.failures[$0] }) {
        ActionFailureView(failure: failure)
      }
      HStack(spacing: 12) {
        Text("\(chosen) of \(rows.count) selected · accepted tasks go to Todo")
          .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
          .frame(maxWidth: .infinity, alignment: .leading)
        if let command {
          CopyValue(value: command.text, title: "Copy command: " + command.title, pill: true)
        }
        Button(sending ? "Accepting…" : chosen == 0 ? "Accept" : "Accept \(chosen)") {
          model.acceptSelectedProposals()
        }.buttonStyle(ActionButtonStyle(prominent: false)).disabled(chosen == 0 || sending)
      }
    }.padding(.leading, 32).padding(.top, 4)
  }

  private func unblockRow(_ ref: String) -> some View {
    let target = model.target(ref)
    let sending = target.map { model.actions.isSending($0) } ?? false
    return VStack(alignment: .leading, spacing: 10) {
      if let failure = target.flatMap({ model.actions.failures[$0] }) {
        ActionFailureView(failure: failure)
      }
      HStack(spacing: 12) {
        Text("Its blockers are done; unblocking returns it to Todo.").font(.system(size: 12))
          .foregroundStyle(Color("SecondaryInk")).frame(maxWidth: .infinity, alignment: .leading)
        Button(sending ? "Unblocking…" : "Unblock") {
          model.perform(.unblock(ref: ref), for: ref)
        }.buttonStyle(ActionButtonStyle(prominent: false)).disabled(sending)
      }
    }
  }

  private func reviewRow(_ review: MyWorkContent.Review) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        StatusDot(color: Color("Warning")).frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(review.task.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).help(
            review.task.title)
          Text(review.metadata).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
        }.frame(maxWidth: .infinity, alignment: .leading)
        CopyValue(value: review.task.ref, title: "Copy task reference")
      }
      if let command = model.reader?.commands(forReview: review.task, workspace: workspace).first {
        CommandBlock(command: command).padding(.leading, 32)
      }
    }
  }

  private func proposalTitle(_ row: MyWorkContent.Proposal) -> some View {
    var title = AttributedString(row.title)
    if !row.metadata.isEmpty {
      var metadata = AttributedString(" · " + row.metadata)
      metadata.foregroundColor = Color("SecondaryInk")
      title.append(metadata)
    }
    return Text(title).font(.system(size: 13)).lineLimit(2)
      .help(row.title + " · " + row.metadata).textSelection(.enabled)
  }

  private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
    HStack(spacing: 10) {
      StatusDot(color: color).frame(width: 22)
      Text("\(title) · \(count)").font(.system(size: 15, weight: .semibold))
    }
  }

  private func otherAttention(_ item: AppAttention) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized)
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        if let ref = item.ref ?? item.task { CopyValue(value: ref, title: "Copy reference") }
      }
      if let title = item.title {
        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2).help(title)
      }
      if let body = item.body { Text(body).font(.system(size: 13)).textSelection(.enabled) }
      if let author = item.author { ActorLabel(actor: author) }
      if !item.refs.isEmpty && (item.refs.count > 1 || item.ref == nil && item.task == nil) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(item.refs, id: \.self) { ref in
              CopyValue(value: ref, title: "Copy task reference")
            }
          }
        }
      }
      if item.kind == "ready", item.refs.count == 1, let ref = item.refs.first {
        unblockRow(ref)
      } else {
        let commands = model.reader?.commands(for: item, workspace: workspace) ?? []
        ForEach(commands, id: \.text) { command in
          CommandBlock(command: command)
        }
      }
    }
  }
}
