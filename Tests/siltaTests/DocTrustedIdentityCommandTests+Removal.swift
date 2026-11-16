import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocTrustedIdentityCommandTests {
  @Test func printedKeepBodyRecoveryRetainsTrustedScopeAndLiteralBody() throws {
    try withScratchDirectory { scratch in
      let store = try DocTrustedIdentityFixture.make(scratch)
      let scope = DocTrustedIdentityFixture.workspace
      let body = Data(
        ("Password=private123 " + String(repeating: "é", count: 40_000) + "\u{0}end").utf8)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [body])
      }
      let file = try removalFile(scratch)
      let arguments = [
        "ws", "edit", scope, "-F", file.path, "--approved", "Remove Acme push", "--json",
      ]
      let refusal = try SiltaBinary.run(arguments, in: scratch, environment: TaskCommandTests.fixed)
      try #require(refusal.termination == .exit(6), "\(refusal.stdout)\(refusal.stderr)")
      let error = try DocEditCommandTests.error(refusal)
      let commands = try #require(error["next"] as? [String])
      let recipe = commands.first ?? ""
      do {
        #expect(error["next_by"] as? String == "human")
        #expect(
          recipe.contains("--ws '" + scope + "' doc edit 'doc:" + DocTrustedIdentityFixture.doc))
        #expect(
          recipe.contains("--keep-body") && recipe.contains("app:" + DocTrustedIdentityFixture.app))
        #expect(recipe.contains("topic:" + DocTrustedIdentityFixture.topic))
      }
      #expect(!refusal.stdout.contains("private123") && !recipe.contains("-F"))
      if recipe.contains("--keep-body") {
        let filled = recipe.replacingOccurrences(of: "<replacement-ref>", with: "topic:replacement")
          .replacingOccurrences(of: "<the human's words>", with: "Reattach Acme rules")
        #expect(try DocTrustedIdentityFixture.replay(filled, in: scratch).termination == .exit(0))
        let removed = try SiltaBinary.run(
          arguments, in: scratch, environment: TaskCommandTests.fixed)
        #expect(removed.termination == .exit(0), "\(removed.stdout)\(removed.stderr)")
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM service") } == 0)
      }
      #expect(try retainedBody(store) == body)
    }
  }

  private func removalFile(_ scratch: URL) throws -> URL {
    let file = scratch.appending(path: "map.yml")
    let yaml = AcmeDocAttachments.yaml(removing: "service")
      .replacingOccurrences(of: "slug: acme", with: "slug: " + DocTrustedIdentityFixture.workspace)
      .replacingOccurrences(of: "slug: api", with: "slug: " + DocTrustedIdentityFixture.app)
      .replacingOccurrences(
        of: "slug: messaging",
        with: "slug: " + DocTrustedIdentityFixture.topic + "}, {slug: replacement")
    try yaml.write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  private func retainedBody(_ store: DatabaseStore) throws -> Data? {
    try store.read {
      try Data.fetchOne(
        $0,
        sql: """
          SELECT CAST(r.body_md AS BLOB) FROM doc_rev r JOIN doc d ON d.id=r.doc_id
          WHERE d.slug=? AND r.rev=d.current_rev
          """, arguments: [DocTrustedIdentityFixture.doc])
    }
  }
}
