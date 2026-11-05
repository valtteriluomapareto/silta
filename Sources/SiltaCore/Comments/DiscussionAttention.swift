import GRDB

struct DiscussionAttention {
  let kind: String
  let post: CommentDetails
  let task: TaskDetails
}

extension TaskService {
  static func attention(for actor: ActorID, workspaceID: Int64, in db: Database) throws
    -> [DiscussionAttention]
  {
    []
  }
}
