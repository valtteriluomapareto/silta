import Foundation
import GRDB

extension TaskService {
  /// Reads local attention in one snapshot. `me` means the captured human;
  /// nil means the caller. Human categories still build actions for the caller.
  /// Reads never update claims, discussion, read markers or task state.
  package func inbox(for target: String? = nil, all: Bool = false) throws -> InboxResult {
    let actor: ActorID
    if let target {
      guard let parsed = target == "me" ? environment.human : ActorID.parse(target) else {
        throw TaskError.invalid(
          "Use a complete human:<name> or agent:<tool>:<session> actor, or me.")
      }
      actor = parsed
    } else {
      actor = environment.actor
    }
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.read {
      try inbox(for: actor, workspace: slug, all: all, at: at, in: $0)
    }
  }

  func inbox(for actor: ActorID, workspace: String, all: Bool, at: Date, in db: Database) throws
    -> InboxResult
  {
    let command = "silta --ws " + shellWord(workspace)
    let attention = try inboxAttention(
      for: actor, workspace: workspace, all: all, at: at, limit: all ? nil : 12, in: db)
    let selected = all ? attention.items : Array(attention.items.prefix(12))
    let reader = try DocProposalInbox(workspace: workspace, at: at, all: all, in: db)
    let groups = try reader.previews(
      selected.compactMap(\.proposalGroup), caller: environment.actor)
    let previews = Dictionary(groups.map { ($0.id, $0) }) { first, _ in first }
    let items = try selected.map { item in
      guard let group = item.proposalGroup else { return item }
      guard let preview = previews[group.id] else { throw StorageError.corrupt }
      return InboxItem(
        kind: "doc_proposal", ref: preview.ref, createdAt: item.createdAt,
        next: preview.commands, docProposal: preview)
    }
    let remaining = attention.total - items.count
    return InboxResult(
      actor: actor.description, items: items, remaining: remaining,
      more: remaining == 0
        ? nil : command + " inbox --for " + shellWord(actor.description) + " --all")
  }

  /// Uncapped eligible questions for the captured human, without document hydration.
  package func questionInbox() throws -> [InboxItem] {
    let actor = environment.human
    let slug = try selected()
    return try environment.db.read { db in
      let workspaceID = try Self.workspaceID(slug, in: db)
      return try Self.attention(for: actor, workspaceID: workspaceID, in: db)
        .filter { $0.kind == "question" }
        .map { inboxItem($0, actor: actor, workspace: slug) }
    }
  }

  /// Ordered attention metadata and its uncapped count inside the caller's snapshot.
  /// The optional window excludes current-task attention when it has separate display slots.
  /// Only document IDs are selected; no proposal previews are hydrated here.
  func inboxAttention(
    for actor: ActorID, workspace slug: String, all: Bool, at: Date, limit: Int? = nil,
    currentTask: String? = nil, in db: Database
  ) throws -> (items: [InboxItem], total: Int) {
    let command = "silta --ws " + shellWord(slug)
    let workspaceID = try Self.workspaceID(slug, in: db)
    let discussion = try Self.attention(for: actor, workspaceID: workspaceID, in: db).map {
      inboxItem($0, actor: actor, workspace: slug)
    }
    guard actor.isHuman else { return (discussion, discussion.count) }
    let urgent = try inboxBlocks(workspaceID, at: at, command: command, in: db) + discussion
    let backlog = try inboxBacklog(workspaceID, at: at, all: all, command: command, in: db)
    let proposals = Array(backlog.prefix { $0.kind == "proposal" })
    let reader = try DocProposalInbox(workspace: slug, at: at, all: all, in: db)
    let count = try reader.count()
    let preceding = urgent.filter { $0.task == nil || $0.task != currentTask }.count
    let groups = try reader.groups(limit: limit.map { max(0, $0 - preceding) })
    let documents = groups.map {
      InboxItem(kind: "doc_proposal", createdAt: $0.newestAt, next: [], proposalGroup: $0)
    }
    let merged = (proposals + documents).enumerated().sorted { left, right in
      let lhs = left.element.createdAt ?? ""
      let rhs = right.element.createdAt ?? ""
      if lhs != rhs { return lhs > rhs }
      let leftDoc = left.element.proposalGroup != nil
      let rightDoc = right.element.proposalGroup != nil
      if leftDoc != rightDoc { return !leftDoc }
      return left.offset < right.offset
    }.map(\.element)
    return (
      urgent + merged + Array(backlog.dropFirst(proposals.count)),
      urgent.count + backlog.count + count
    )
  }

  private func inboxItem(_ attention: DiscussionAttention, actor: ActorID, workspace: String)
    -> InboxItem
  {
    let post = attention.post
    let task = attention.task
    let command = "silta --ws " + shellWord(workspace)
    let read = command + " task show " + shellWord(task.ref) + " --timeline"
    let next: [String]
    if attention.kind == "question",
      environment.actor.isHuman || post.mentions.contains(environment.actor.description)
    {
      next = [
        command + " comment " + shellWord(task.ref) + " --kind answer --reply-to "
          + shellWord(post.ref) + " -F <file>"
      ]
    } else if attention.kind == "answer", let question = attention.question,
      Self.canAcceptAnswer(
        post.actor, question: question, claimer: task.claimedBy,
        caller: environment.actor)
    {
      next = [command + " comment accept " + shellWord(post.ref)]
    } else if let confirmation = relayConfirmation(attention, actor: actor, workspace: workspace) {
      next = [confirmation, read]
    } else {
      next = [read]
    }
    let relayers =
      attention.kind == "question"
      ? attention.answers.filter {
        ActorID.parse($0.actor)?.isHuman == false && !post.mentions.contains($0.actor)
      }.map(\.actor) : []
    return InboxItem(
      kind: attention.kind, ref: post.ref, task: task.ref, author: post.actor, body: post.body,
      createdAt: post.createdAt, next: next, postKind: post.kind, replyTo: post.replyTo,
      relayedBy: relayers.isEmpty ? nil : Set(relayers).sorted())
  }

  private func relayConfirmation(
    _ attention: DiscussionAttention, actor: ActorID, workspace: String
  ) -> String? {
    let caller = environment.actor
    guard let question = attention.question,
      let resolve = Self.relayResolutionCommand(question, caller: caller, workspace: workspace)
    else { return nil }

    if actor.isHuman, question.mentions.contains(actor.description),
      let own = attention.answers.first(where: { $0.actor == caller.description })
    {
      return Self.confirmationHint(own.ref, question: question.ref, resolve: resolve)
    }
    let post = attention.post
    guard actor == caller, attention.kind == "answer",
      Self.isOwnHumanAnswer(post.actor, question: question, caller: caller)
    else { return nil }
    let recipients = question.humanRecipients
    let recipientList = recipients.map { HumanText.line($0.description) }.joined(separator: ", ")
    let addressing =
      recipients.contains(environment.human)
      ? "" : "Ask " + (recipients.count == 1 ? "" : "one of ") + recipientList + ". "
    return Self.confirmationHint(
      post.ref, question: question.ref, resolve: resolve, addressing: addressing)
  }

  private static func confirmationHint(
    _ answer: String, question: String, resolve: String, addressing: String = ""
  ) -> String {
    "ask human: " + addressing + "Does " + answer + " relay your confirmed answer to " + question
      + "? Only if yes: " + resolve
  }
}
