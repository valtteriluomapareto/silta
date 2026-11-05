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
    return try environment.db.read { db in
      try inbox(for: actor, workspace: slug, all: all, in: db)
    }
  }

  /// The same attention inside the caller's read snapshot; `all` lifts the cap.
  func inbox(for actor: ActorID, workspace slug: String, all: Bool, in db: Database) throws
    -> InboxResult
  {
    let command = "silta --ws " + shellWord(slug)
    let workspaceID = try Self.workspaceID(slug, in: db), at = environment.clock.now()
    let discussion = try Self.attention(for: actor, workspaceID: workspaceID, in: db).map {
      inboxItem($0, actor: actor, command: command)
    }
    let attention =
      actor.isHuman
      ? try inboxBlocks(workspaceID, at: at, command: command, in: db) + discussion
        + inboxBacklog(workspaceID, at: at, all: all, command: command, in: db)
      : discussion
    let items = all ? attention : Array(attention.prefix(12))
    let remaining = attention.count - items.count
    return InboxResult(
      actor: actor.description, items: items, remaining: remaining,
      more: remaining == 0
        ? nil : command + " inbox --for " + shellWord(actor.description) + " --all")
  }

  private func inboxItem(_ attention: DiscussionAttention, actor: ActorID, command: String)
    -> InboxItem
  {
    let post = attention.post
    let task = attention.task
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
        post.actor, asker: question.actor, claimer: task.claimedBy,
        caller: environment.actor.description)
    {
      next = [command + " comment accept " + shellWord(post.ref)]
    } else if let confirmation = relayConfirmation(attention, actor: actor, command: command) {
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
    _ attention: DiscussionAttention, actor: ActorID, command: String
  ) -> String? {
    guard actor.isHuman, !environment.actor.isHuman, let question = attention.question,
      question.mentions.contains(actor.description),
      !question.mentions.contains(environment.actor.description),
      let own = attention.answers.first(where: { $0.actor == environment.actor.description })
    else { return nil }
    return "ask human: Does " + own.ref + " relay your confirmed answer to " + question.ref
      + "? Only if yes: " + command + " comment resolve " + shellWord(question.ref)
      + " -m \"<confirmed answer>\""
  }
}
