/// A body-free receipt for a stored pending revision.
struct DocProposalResult: Sendable {
  let ref: String
  let warnings: [OutputWarning]
  let workspace: String
}
