import Foundation
import SiltaAppSupport
import SwiftUI

struct MyWorkView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      if let data = model.visibleData, let snapshot = data.snapshot {
        let content = MyWorkContent(
          snapshot: snapshot, all: model.allWaiting, search: model.search, now: data.checkedAt)
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
                    .toggleStyle(.checkbox).accessibilityLabel("Select \(row.ref)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                  Button("Open") { model.inspect(task: row.ref) }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Color("TideText"))
                    .accessibilityLabel("Open \(row.ref) in the inspector")
                  CopyValue(value: row.ref, title: "Copy task reference", warning: true)
                    .fixedSize()
                }.padding(.leading, 32).frame(minHeight: 28)
              }
              proposalFooter(content.tasks)
            }.padding(.horizontal, 22).padding(.vertical, 16).seaPane()
          }
          ForEach(content.followUps) { followUp in
            FollowUpCard(model: model, followUp: followUp).padding(.horizontal, 22)
              .padding(.vertical, 16).seaPane()
          }
          ForEach(content.other, id: \.stableID) { item in
            otherAttention(item).padding(.horizontal, 22).padding(.vertical, 16).seaPane()
          }
          HStack(spacing: 6) {
            Text(
              MyWorkContent.footer(
                remaining: content.remaining, showingAll: model.showingAllWaiting,
                loaded: model.allWaiting != nil || model.allWaitingFailure != nil)
            ).foregroundStyle(Color("SecondaryInk"))
            Button(model.showingAllWaiting ? "Show fewer" : "Show all") {
              if model.showingAllWaiting {
                model.showFewerWaiting()
              } else {
                model.showAllWaiting()
              }
            }.buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Color("TideText"))
          }.font(.system(size: 13)).padding(.horizontal, 22)
          if let failure = model.allWaitingFailure {
            Label(
              "Couldn't read the whole inbox: " + failure, systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
            .padding(.horizontal, 22)
          }
        }.padding(.bottom, 24)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }.foregroundStyle(Color("Ink"))
  }

  var workspace: String { model.workspace ?? "" }

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
    }.contentShape(.rect).accessibilityElement(children: .contain)
      .taskMenu(model.menuItems(for: review.task), model: model)
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
      if let ref = MyWorkContent.unblockRef(item) {
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
