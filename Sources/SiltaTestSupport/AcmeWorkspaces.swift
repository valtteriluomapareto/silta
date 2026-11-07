package import Foundation
import GRDB
import SiltaCore

package enum AcmeWorkspaces {
  package static func setup(_ scratch: URL) throws -> URL {
    let fixture = try AcmeFixtures.make(at: scratch.appending(path: "fixtures"))
    guard fixture.termination == .exit(0) else { throw Error(stderr: fixture.stderr) }
    let repo = scratch.appending(path: "fixtures/acme-platform")
    let config = try WorkspaceConfig.parse(
      """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: platform}]
      apps:
        - {slug: platform, repo: platform, ref: origin/master}
        - {slug: portal, repo: platform, ref: origin/portal, prod_ref: origin/portal-prod}
        - {slug: api, repo: platform, ref: origin/api, prod_ref: origin/api-prod}
        - {slug: console, repo: platform, ref: origin/api, subpath: apps/console}
      """)
    try store(scratch).write {
      try config.apply(
        in: $0, ids: SeededIDGenerator(seed: 1), at: Date(timeIntervalSince1970: 1_700_000_000))
      try $0.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo", arguments: [repo.path])
    }
    try WorkspaceSelection.use("acme", in: store(scratch))
    return repo
  }

  private static func store(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  private struct Error: Swift.Error {
    let stderr: String
  }
}
