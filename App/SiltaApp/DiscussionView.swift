import SiltaAppSupport
import SwiftUI

/// The inspector's discussion: threads with their replies inside the root's rail, long
/// posts clamped to four lines, resolved threads folded to one line, and a reply box
/// inside a thread. Expansion lasts while the task stays selected.
struct DiscussionView: View {
  @Bindable var model: AppModel
  let task: AppTask
  @State private var expandedPosts: Set<String> = []
  @State private var expandedThreads: Set<String> = []
  @State private var openedResolved: Set<String> = []
  @State private var replyingTo: String?

  private var content: DiscussionContent {
    DiscussionContent(comments: task.comments, resolved: task.resolvedComments)
  }
  private var human: String { model.reader?.human ?? "" }

  var body: some View {
    let content = content
    VStack(alignment: .leading, spacing: 14) {
      Overline(
        content.isEmpty
          ? "Discussion"
          : "Discussion · \(content.count) \(content.count == 1 ? "thread" : "threads")")
      if content.isEmpty {
        Text("No discussion yet").font(.system(size: 13)).foregroundStyle(Color("SecondaryInk"))
      }
      ForEach(content.open) { thread in
        threadView(thread)
      }
      ForEach(content.resolved) { thread in
        resolvedView(thread)
      }
    }
  }

  private func threadView(_ thread: DiscussionContent.Thread) -> some View {
    let expanded = expandedThreads.contains(thread.id)
    return VStack(alignment: .leading, spacing: 10) {
      post(thread.root, isReply: false)
      if thread.foldedCount(expanded: expanded) > 0 {
        Button {
          expandedThreads.insert(thread.id)
        } label: {
          Label(
            "\(thread.foldedCount(expanded: expanded)) earlier "
              + (thread.foldedCount(expanded: expanded) == 1 ? "reply" : "replies"),
            systemImage: "chevron.down"
          )
          .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
          .padding(.horizontal, 10).padding(.vertical, 4)
          .background(Color("Ink").opacity(0.05), in: .capsule)
        }.buttonStyle(.plain)
      }
      ForEach(thread.visibleReplies(expanded: expanded), id: \.ref) { reply in
        post(reply, isReply: true)
          .padding(.leading, 12)
          .overlay(alignment: .leading) {
            Rectangle().fill(Self.railColor(reply.actor).opacity(0.45)).frame(width: 2)
          }
      }
      if thread.canReply { threadFooter(thread) }
    }
    .padding(.leading, 12)
    .overlay(alignment: .leading) {
      Rectangle().fill(Self.railColor(thread.root.actor)).frame(width: 2)
    }
  }

  @ViewBuilder private func threadFooter(_ thread: DiscussionContent.Thread) -> some View {
    // An open question to the human is answered, sharing the inspector's answer draft;
    // any other thread gets a reply draft of its own.
    let answers = thread.asks(human)
    let targetRef = answers ? thread.id : AppModel.replyTarget(thread.id)
    if replyingTo == thread.id, let target = model.target(targetRef) {
      ActionComposer(
        model: model, target: target,
        placeholder: "\(answers ? "Answer" : "Reply to") \(thread.id)",
        sendTitle: answers ? "Send answer" : "Reply", command: nil,
        caption: (answers ? "Answers " : "Replies to ") + thread.id, cancel: { replyingTo = nil },
        send: {
          Task {
            let sent =
              answers
              ? model.answer(question: thread.id, task: task.ref)
              : model.reply(to: thread.id, task: task.ref)
            await sent?.value
            if sent != nil, model.actions.failures[target] == nil { replyingTo = nil }
          }
        })
    } else {
      HStack(spacing: 14) {
        if model.writer != nil, thread.canReply {
          Button(answers ? "Answer" : "Reply") { replyingTo = thread.id }.buttonStyle(.plain)
            .foregroundStyle(Color("TideText"))
            .accessibilityLabel((answers ? "Answer " : "Reply to ") + thread.id)
        }
        // An open question to the human is answered, never closed without a word.
        if model.writer != nil, !thread.resolved, !answers {
          resolveButton(thread, reopen: false)
        }
        Text(thread.state).foregroundStyle(Color("SecondaryInk"))
      }.font(.system(size: 12))
      resolveFailure(thread)
    }
  }

  /// A refused Resolve or Reopen, shown under the thread's footer.
  @ViewBuilder private func resolveFailure(_ thread: DiscussionContent.Thread) -> some View {
    if let failure = model.target(AppModel.resolveTarget(thread.id)).flatMap({
      model.actions.failures[$0]
    }) {
      ActionFailureView(failure: failure)
    }
  }

  /// Resolves an open thread or reopens a resolved one; a failure shows under it.
  @ViewBuilder private func resolveButton(_ thread: DiscussionContent.Thread, reopen: Bool)
    -> some View
  {
    let target = model.target(AppModel.resolveTarget(thread.id))
    let sending = target.map { model.actions.isSending($0) } ?? false
    Button(reopen ? "Reopen" : "Resolve") {
      if reopen { model.reopen(thread: thread.id) } else { model.resolve(thread: thread.id) }
    }.buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Color("TideText"))
      .disabled(sending)
      .accessibilityLabel((reopen ? "Reopen " : "Resolve ") + thread.id)
  }

  @ViewBuilder private func resolvedView(_ thread: DiscussionContent.Thread) -> some View {
    let opened = openedResolved.contains(thread.id)
    VStack(alignment: .leading, spacing: 10) {
      Button {
        if opened { openedResolved.remove(thread.id) } else { openedResolved.insert(thread.id) }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color("Success"))
            .accessibilityHidden(true)
          Text(opened ? resolvedBy(thread) : "Resolved · " + summary(thread))
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          if !opened, !thread.replies.isEmpty {
            Text(DiscussionContent.replyCount(thread.replies.count))
              .foregroundStyle(Color("SecondaryInk"))
          }
          Image(systemName: opened ? "chevron.up" : "chevron.right")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color("SecondaryInk"))
            .accessibilityHidden(true)
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color("Ink").opacity(0.04), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
      }.buttonStyle(.plain)
        .accessibilityLabel(opened ? resolvedBy(thread) : "Resolved thread, " + summary(thread))
        .accessibilityHint(opened ? "Folds the thread" : "Shows the thread")
      if opened {
        threadView(thread).opacity(0.8)
        if model.writer != nil { resolveButton(thread, reopen: true).font(.system(size: 12)) }
        resolveFailure(thread)
      }
    }
  }

  private func post(_ comment: AppComment, isReply: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if isReply {
          Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
            .foregroundStyle(Color("SecondaryInk")).accessibilityHidden(true)
        }
        Text(header(comment, isReply: isReply)).font(.system(size: 11))
          .foregroundStyle(Color("SecondaryInk")).lineLimit(1)
        if comment.accepted {
          Label("Accepted", systemImage: "checkmark").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color("Success")).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color("Success").opacity(0.14), in: .capsule)
        }
        Spacer(minLength: 4)
        CopyValue(value: comment.ref, title: "Copy comment reference", compact: true)
      }
      ClampedBody(
        text: comment.body, ref: comment.ref,
        expanded: Binding(
          get: { expandedPosts.contains(comment.ref) },
          set: {
            if $0 { expandedPosts.insert(comment.ref) } else { expandedPosts.remove(comment.ref) }
          }
        ))
    }
  }

  private func header(_ comment: AppComment, isReply: Bool) -> AttributedString {
    var name = AttributedString(DiscussionContent.name(comment.actor, human: human))
    name.foregroundColor = Color("Ink")
    name.font = .system(size: 11, weight: .semibold)
    let rest = [
      DiscussionContent.kind(comment, isReply: isReply, human: human), age(comment.createdAt),
    ]
    .compactMap { $0 }
    return name + AttributedString(rest.map { " · " + $0 }.joined())
  }

  private func summary(_ thread: DiscussionContent.Thread) -> String {
    DiscussionContent.summary(thread, human: human)
  }

  private func resolvedBy(_ thread: DiscussionContent.Thread) -> String {
    let who = thread.root.resolvedBy.map { DiscussionContent.name($0, human: human) }
    return ["Resolved" + (who.map { " by " + $0 } ?? ""), age(thread.root.resolvedAt)]
      .compactMap { $0 }.joined(separator: " · ")
  }

  private func age(_ value: String?) -> String? {
    guard let now = model.visibleData?.checkedAt else { return value }
    return RelativeAge.text(value, now: now) ?? value
  }

  /// The rail colour of an author: Codex brass, other agents tide, humans grey.
  static func railColor(_ actor: String) -> Color {
    let presentation = ActorPresentation(actor)
    return presentation.isCodex
      ? Color("Warning") : actor.hasPrefix("agent:") ? Color("AccentColor") : Color("SecondaryInk")
  }
}

/// A post body clamped to four lines, with Show more only when the clamp cut it.
private struct ClampedBody: View {
  let text: String
  let ref: String
  @Binding var expanded: Bool
  @State private var fullHeight: CGFloat = 0
  @State private var clampedHeight: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(text).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
        .lineLimit(expanded ? nil : 4)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          if !expanded { clampedHeight = $0 }
        }
        .background(alignment: .topLeading) {
          Text(text).font(.system(size: 13)).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true).hidden()
            .onGeometryChange(for: CGFloat.self) {
              $0.size.height
            } action: {
              fullHeight = $0
            }
        }
      if expanded || fullHeight > clampedHeight + 1 {
        Button {
          expanded.toggle()
        } label: {
          Label(
            expanded ? "Show less" : "Show more",
            systemImage: expanded ? "chevron.up" : "chevron.down"
          )
          .labelStyle(TrailingIconLabelStyle())
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color("TideText"))
        }.buttonStyle(.plain)
          .accessibilityLabel((expanded ? "Show less of " : "Show more of ") + ref)
      }
    }
  }
}

private struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.title
      configuration.icon.font(.system(size: 9, weight: .semibold))
    }
  }
}
