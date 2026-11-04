import Foundation

extension LocationService {
  func distance(_ input: LocationResult, context: LocationContext, cacheWrites: Bool = true)
    async throws -> LocationResult
  {
    var result = input
    let candidates = result.candidates
    let refs = context.refs
    let path = context.path
    let git = context.git
    guard !refs.isEmpty else { return result }
    if try await git.required(["rev-parse", "--is-shallow-repository"]) == "true" {
      result.reason = "shallow"
      return result
    }
    let cache = LocationCache(path: environment.home.url.appending(path: "index.db").path)
    let key = LocationCache.key(
      [path.path, result.head] + candidates.map { "\($0.id):\($0.app):\($0.ref)" }
        + refs.map { "\($0.0):\($0.1)" })
    let distance: LocationDistance
    if let cached = cache.read(key: key, location: path.path) {
      distance = cached
    } else {
      var scores: [(String, Int)] = []
      for (app, sha) in refs {
        guard
          let ahead = try await git.value(
            ["rev-list", "--count", sha + ".." + result.head],
            optional: true), let a = Int(ahead),
          let behind = try await git.value(
            ["rev-list", "--count", result.head + ".." + sha],
            optional: true), let b = Int(behind)
        else {
          result.reason = "shallow"
          return result
        }
        scores.append((app, a + b))
      }
      distance = LocationDistance.choose(scores)
      if cacheWrites { cache.write(distance, key: key, location: path.path) }
    }
    result.app = distance.app
    result.confidence = distance.confidence
    result.retryApps =
      distance.ranked + candidates.map(\.app).filter { !distance.ranked.contains($0) }
    if refs.count != candidates.count {
      result.app = nil
      result.confidence = "low"
    }
    result.reason = "distance"
    return result
  }
}
