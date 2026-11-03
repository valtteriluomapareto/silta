import Foundation
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct InitCommandTests {
  @Test func bareInitCreatesOnlyDatabaseAndPointsToHumanEdit() throws {
    try withScratchDirectory { scratch in
      for json in [false, true] {
        let result = try SiltaBinary.run(["init"] + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(0))
        Golden.forTests().check(result.stdout, json ? "init.json" : "init.txt")
        #expect(result.stderr.isEmpty)
      }
      #expect(
        FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path))
    }
  }

  @Test func fetchWithoutSelectedWorkspaceIsNotFound() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["repo", "fetch", "--json"], in: scratch)
      #expect(result.termination == .exit(2))
      #expect(result.stdout.contains("silta ws ls"))
    }
  }
  @Test func fixtureScanFetchAndPathOnlyRescan() throws {
    try withScratchDirectory { scratch in
      let root = ScenarioRunner.repository
      let fixtures = scratch.appending(path: "acme")
      let generated = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"),
        [root.appending(path: "scripts/make-fixtures.sh").path, fixtures.path], in: scratch)
      #expect(generated.termination == .exit(0))
      let scan = try SiltaBinary.run(["init", "--scan", fixtures.path, "--json"], in: scratch)
      #expect(scan.termination == .exit(0))
      Golden.forTests().check(scan.stdout, "init-scan.json")
      let use = try SiltaBinary.run(["ws", "use", "acme"], in: scratch)
      #expect(use.termination == .exit(0))
      for json in [false, true] {
        let fetched = try SiltaBinary.run(
          ["repo", "fetch", "acme-platform"] + (json ? ["--json"] : []), in: scratch)
        #expect(fetched.termination == .exit(0))
        Golden.forTests().check(fetched.stdout, json ? "repo-fetch.json" : "repo-fetch.txt")
        #expect(fetched.stderr.isEmpty)
      }
      let again = try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch)
      #expect(again.termination == .exit(0))
      Golden.forTests().check(again.stdout, "init-scan.txt")
    }
  }

}
