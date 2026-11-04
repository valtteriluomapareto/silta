import Foundation

struct LocationContext {
  let path: URL
  let repo: LocationRepository
  let git: LocationGit
  let candidates: [LocationCandidate]
}
