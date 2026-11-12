import Foundation
import GRDB

/// Owns document rows and their current attachment projection in the caller's transaction.
struct DocStore {
  let workspace: Int64
  let transaction: StorageTransaction
  let actor: ActorID
  let ids: any IDGenerator
  let at: Date

  func accept(_ draft: DocDraft) throws -> DocRevision {
    throw TaskError.invalid("Doc storage is unavailable.")
  }

  func archive(_ slug: String) throws -> Bool {
    throw TaskError.invalid("Doc storage is unavailable.")
  }

  static func revision(_ slug: String, revision: Int, workspace: Int64, in db: Database) throws
    -> DocRevision
  {
    throw TaskError.notFound("doc " + slug)
  }
}
