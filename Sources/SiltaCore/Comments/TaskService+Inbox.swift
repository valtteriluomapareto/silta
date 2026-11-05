import GRDB

extension TaskService {
  /// Reads discussion attention in one snapshot. `me` means the captured human;
  /// nil means the caller. Promoted tasks are excluded because local actions refuse.
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
    let slug = try selected(), name = actor.description
    let command = "silta --ws " + shellWord(slug)
    return try environment.db.read { db in
      let workspaceID = try Self.workspaceID(slug, in: db)
      let tasks = try Row.fetchAll(
        db,
        sql: Self.query + """
          \nWHERE task.workspace_id=? AND task.external_ref IS NULL
          AND EXISTS(SELECT 1 FROM comment WHERE task_id=task.id AND deleted_at IS NULL)
          """, arguments: [workspaceID]
      ).map { TaskDetails(row: $0) }
      var attention: [(id: Int64, item: InboxItem)] = []
      for task in tasks {
        let posts = try Self.discussion(task, timeline: true, in: db)
        let roots = Dictionary(
          uniqueKeysWithValues: posts.filter { $0.replyTo == nil }.map { ($0.ref, $0) })
        for post in posts where !post.deleted {
          if let item = inboxItem(
            post, root: roots[post.replyTo ?? post.ref], task: task, actor: actor, command: command)
          {
            attention.append((post.id, item))
          }
        }
      }
      attention.sort {
        if $0.item.rank != $1.item.rank { return $0.item.rank < $1.item.rank }
        if $0.item.createdAt != $1.item.createdAt { return $0.item.createdAt < $1.item.createdAt }
        return $0.id < $1.id
      }
      let items = (all ? attention : Array(attention.prefix(12))).map(\.item)
      let remaining = attention.count - items.count
      return InboxResult(
        actor: name, items: items, remaining: remaining,
        more: remaining == 0 ? nil : command + " inbox --for " + shellWord(name) + " --all")
    }
  }

  private func inboxItem(
    _ post: CommentDetails, root: CommentDetails?, task: TaskDetails, actor: ActorID,
    command: String
  ) -> InboxItem? {
    let name = actor.description
    let kind: String
    let next: [String]
    if post.kind == "question", post.resolvedAt == nil, post.answered == false,
      post.mentions.contains(name)
    {
      kind = "question"
      next = [
        command + " comment " + shellWord(task.ref) + " --kind answer --reply-to "
          + shellWord(post.ref) + " -F <file>",
        command + " comment resolve " + shellWord(post.ref) + " -m <reason>",
      ]
    } else if post.kind == "answer", !post.accepted, let root,
      root.kind == "question", !root.deleted, root.resolvedAt == nil,
      root.actor == name || task.claimedBy == name
    {
      kind = "answer"
      let canAccept =
        root.actor == environment.actor.description
        || task.claimedBy == environment.actor.description
      next = [
        canAccept
          ? command + " comment accept " + shellWord(post.ref)
          : command + " comment resolve " + shellWord(root.ref) + " -m <reason>"
      ]
    } else if !actor.isHuman, task.claimedBy == name, post.actor != name,
      let boundary = task.claimedAt, post.createdAt > boundary
    {
      kind = "comment"
      next = [command + " task show " + shellWord(task.ref) + " --timeline"]
    } else {
      return nil
    }
    return InboxItem(
      kind: kind, ref: post.ref, task: task.ref, author: post.actor, body: post.body,
      createdAt: post.createdAt, next: next)
  }
}
