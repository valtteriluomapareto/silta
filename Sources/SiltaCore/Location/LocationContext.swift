import Foundation

struct LocationContext {
  let path: URL
  let root: URL
  let repo: LocationRepository
  let git: LocationGit
  let candidates: [LocationCandidate]
  let refs: [(String, String)]
  let warnings: [OutputWarning]
  var displayRoot: URL?
}
