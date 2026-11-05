import GRDB

struct DiscussionAttention {
  let kind: String
  let post: CommentDetails
  let task: TaskDetails
  let question: CommentDetails?
  let answers: [CommentDetails]

  var rank: Int { kind == "question" ? 0 : kind == "answer" ? 1 : 2 }
}

extension TaskService {
  /// Returns uncapped discussion attention inside the caller's read snapshot.
  /// Classification has no caller-specific actions and does not mutate storage.
  static func attention(for actor: ActorID, workspaceID: Int64, in db: Database) throws
    -> [DiscussionAttention]
  {
    let tasks = try Row.fetchAll(
      db,
      sql: query + """
        \nWHERE task.workspace_id=? AND task.external_ref IS NULL
        AND EXISTS(SELECT 1 FROM comment WHERE task_id=task.id AND deleted_at IS NULL)
        """, arguments: [workspaceID]
    ).map { TaskDetails(row: $0) }
    let result = try tasks.flatMap { task -> [DiscussionAttention] in
      let posts = try discussion(task, timeline: true, in: db)
      let roots = Dictionary(
        uniqueKeysWithValues: posts.filter { $0.replyTo == nil }.map { ($0.ref, $0) })
      return posts.compactMap { post in
        classify(
          post, question: roots[post.replyTo ?? post.ref], posts: posts, task: task, actor: actor)
      }
    }
    return result.sorted {
      if $0.rank != $1.rank { return $0.rank < $1.rank }
      if $0.post.createdAt != $1.post.createdAt { return $0.post.createdAt < $1.post.createdAt }
      return $0.post.id < $1.post.id
    }
  }

  private static func classify(
    _ post: CommentDetails, question: CommentDetails?, posts: [CommentDetails],
    task: TaskDetails, actor: ActorID
  ) -> DiscussionAttention? {
    guard !post.deleted else { return nil }
    let name = actor.description
    let kind: String
    if post.kind == "answer", post.actor == name, question?.actor != name { return nil }
    if post.kind == "question", post.resolvedAt == nil, post.answered == false,
      post.mentions.contains(name)
    {
      kind = "question"
    } else if post.kind == "answer", !post.accepted, let question,
      question.kind == "question", !question.deleted, question.resolvedAt == nil,
      question.actor == name || task.claimedBy == name
    {
      kind = "answer"
    } else if !actor.isHuman, task.claimedBy == name,
      let boundary = task.claimedAt, post.createdAt > boundary
    {
      kind = "discussion"
    } else {
      return nil
    }
    let answers = posts.filter { $0.kind == "answer" && !$0.deleted && $0.replyTo == question?.ref }
    return DiscussionAttention(
      kind: kind, post: post, task: task, question: question, answers: answers)
  }
}
