import Foundation
import GRDB

struct DocProposalInbox {
  let workspace: String
  let workspaceID: Int64
  let at: Date
  let all: Bool
  let db: Database

  init(workspace: String, at: Date, all: Bool = false, in db: Database) throws {
    self.workspace = workspace
    workspaceID = try TaskService.workspaceID(workspace, in: db)
    self.at = at
    self.all = all
    self.db = db
  }

  func count() throws -> Int { throw DocError.notFound("document proposals") }
  func groups(limit: Int? = nil) throws -> [DocProposalGroup] {
    throw DocError.notFound("document proposals")
  }
  func previews(_ groups: [DocProposalGroup]) throws -> [DocProposalPreviewGroup] {
    throw DocError.notFound("document proposals")
  }
}
