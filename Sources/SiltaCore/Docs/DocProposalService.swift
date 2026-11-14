/// Captures supplied document knowledge without accepting it or invoking Git.
struct DocProposalService {
  let environment: SiltaEnvironment
  var workspace: String?
  var approved: String?

  func propose(_ request: DocProposalRequest, input: (() throws -> String)?) throws
    -> DocProposalResult
  {
    throw DocError.notFound(request.slug)
  }
}
