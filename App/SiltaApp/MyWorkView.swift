import Foundation
import SiltaAppSupport
import SwiftUI

struct MyWorkView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      if let data = model.visibleData, let snapshot = data.snapshot {
        let content = MyWorkContent(snapshot: snapshot, search: model.search, now: data.checkedAt)
        LazyVStack(alignment: .leading, spacing: 22) {
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
            questionRow(question)
            Divider()
          }
          ForEach(content.reviews) { review in
            reviewRow(review)
            Divider()
          }
          if !content.documents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              sectionHeader(
                "Doc proposals", count: content.documents.count, color: Color("Warning"))
              ForEach(content.documents) { row in
                HStack(spacing: 10) {
                  proposalTitle(row).frame(maxWidth: .infinity, alignment: .leading)
                  Button("Show changes") { model.openDocument(row.ref) }
                    .buttonStyle(CompactActionStyle())
                  CopyValue(value: row.ref, title: "Copy document reference")
                    .lineLimit(1).truncationMode(.middle).frame(width: 196, alignment: .trailing)
                }.padding(.leading, 28).frame(minHeight: 30)
              }
              if let command = model.reader?.documentTriageCommand(workspace: workspace) {
                CommandBlock(command: command).padding(.leading, 28)
              }
            }
            Divider()
          }
          if !content.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              sectionHeader("Task proposals", count: content.tasks.count, color: .secondary)
              ForEach(content.tasks) { row in
                HStack(spacing: 10) {
                  proposalTitle(row).frame(maxWidth: .infinity, alignment: .leading)
                  CopyValue(value: row.ref, title: "Copy task reference").fixedSize()
                }.padding(.leading, 28).frame(minHeight: 28)
              }
              if let first = content.tasks.first,
                let command = model.reader?.commands(for: first.item, workspace: workspace).first
              {
                CommandBlock(command: command).padding(.leading, 28)
              }
            }
          }
          ForEach(content.other, id: \.stableID) { item in
            Divider()
            otherAttention(item)
          }
          if content.remaining > 0 {
            Text("\(content.remaining) more waiting items").font(
              .system(size: 14, weight: .semibold))
            if let command = model.reader?.inboxCommand(workspace: workspace) {
              CommandBlock(command: command)
            }
          }
        }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 24)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }.foregroundStyle(Color("Ink"))
  }

  private var workspace: String { model.workspace ?? "" }

  private func questionRow(_ question: MyWorkContent.Question) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        if let author = question.item.author {
          ActorLabel(actor: author).labelStyle(.iconOnly).accessibilityHidden(true).frame(width: 18)
        }
        Text(question.metadata).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
          .lineLimit(1).help(question.metadata)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let ref = question.ref { CopyValue(value: ref, title: "Copy task reference") }
      }
      Text(question.headline).font(.system(size: 17, weight: .semibold)).lineLimit(2)
        .help(question.headline).textSelection(.enabled).padding(.leading, 28)
      if let reader = model.reader,
        let command = question.command(reader: reader, workspace: workspace)
      {
        CommandBlock(command: command).padding(.leading, 28)
      }
    }
  }

  private func reviewRow(_ review: MyWorkContent.Review) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        StatusDot(color: Color("Warning")).frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(review.task.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).help(
            review.task.title)
          Text(review.metadata).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
        }.frame(maxWidth: .infinity, alignment: .leading)
        CopyValue(value: review.task.ref, title: "Copy task reference")
      }
      if let command = model.reader?.commands(forReview: review.task, workspace: workspace).first {
        CommandBlock(command: command).padding(.leading, 28)
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
      StatusDot(color: color).frame(width: 18)
      Text("\(title) · \(count)").font(.system(size: 14, weight: .semibold))
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
      let commands = model.reader?.commands(for: item, workspace: workspace) ?? []
      ForEach(commands, id: \.text) { command in
        CommandBlock(command: command)
      }
    }
  }
}
