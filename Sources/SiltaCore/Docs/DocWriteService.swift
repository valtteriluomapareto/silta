import Foundation

struct DocEditRequest {
  var slug: String
  var title: String?
  var kind: String?
  var about: [String]?
  var allowSecret = false
  var keepBody = false
}

struct DocWriteResult {
  let ref: String
  let warnings: [OutputWarning]
}

struct DocWriteService {
  let environment: SiltaEnvironment
  var workspace: String?
  var approved: String?

  func edit(_ request: DocEditRequest, input: (() throws -> String)?) async throws -> DocWriteResult
  {
    throw DocError.invalid("Document writes are unavailable.")
  }
}
