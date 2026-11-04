import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct CodePartialCloneTests {
  @Test(arguments: ["show", "grep"])
  func codeReadsFetchPromisedBlobsWithoutCheckout(verb: String) throws {
    try withScratchDirectory { scratch in
      let fixture = CodeCommandTests()
      let full = try fixture.setup(scratch)
      let origin = scratch.appending(path: "fixtures/acme-origin.git")
      try fixture.git(["config", "uploadpack.allowFilter", "true"], origin, scratch)
      let clone = scratch.appending(path: "blobless")
      try fixture.git(
        ["clone", "--filter=blob:none", "--no-checkout", origin.absoluteString, clone.path],
        scratch, scratch)
      let blob = try fixture.git(["rev-parse", "origin/portal:portal/README.md"], full, scratch)
        .trimmingCharacters(in: .newlines)
      let missing = try probe(blob, clone: clone, scratch: scratch)
      try #require(
        missing.termination != .exit(0), "The fixture must leave the promised blob absent.")
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
      try store.write {
        try $0.database.execute(sql: "UPDATE repo_path SET path=?", arguments: [clone.path])
      }
      let args =
        verb == "show"
        ? ["code", "show", "portal", "portal/README.md", "--json"]
        : ["code", "grep", "portal", "Acme portal", "--json"]
      let result = try SiltaBinary.run(args, in: scratch)
      try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      let expected = verb == "show" ? "Acme portal\n" : "portal/README.md:1:Acme portal\n"
      #expect(try fixture.envelope(result.stdout)["output"] as? String == expected)
      #expect(try probe(blob, clone: clone, scratch: scratch).termination == .exit(0))
      #expect(try FileManager.default.contentsOfDirectory(atPath: clone.path) == [".git"])
    }
  }

  private func probe(_ blob: String, clone: URL, scratch: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), ["cat-file", "-e", blob],
      in: scratch, cwd: clone, environment: ["GIT_NO_LAZY_FETCH": "1"])
  }
}
