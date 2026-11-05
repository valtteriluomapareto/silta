import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

extension BriefCommandTests {
  @Test func nonDefaultSettingsExplainActualPolicy() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      for (gate, gloss) in [
        ("any", "warn if latest review requests changes"),
        ("human", "human approval required before done"),
      ] {
        try settings(
          """
          {"review_gate":"\(gate)","archive_after_days":3,"stale_days":7,"proposals":"ask"}
          """, scratch)
        let line =
          "settings: proposals: ask (ask in chat before adding a task); "
          + "review_gate: \(gate) (\(gloss)); "
          + "archive_after_days: 3 (days before closed tasks archive); "
          + "stale_days: 7 (days before docs are stale)\n"
        for mode in [[], ["--short"]] {
          let result = try run(mode + ["--budget", "1"], repo, scratch)
          #expect(result.stdout.contains(line))
          let data = try fixture.data(run(mode + ["--budget", "1", "--json"], repo, scratch))
          let policy = try #require(data["settings"] as? [String: Any])
          #expect(policy["review_gate"] as? String == gate)
          #expect(policy["archive_after_days"] as? Int == 3)
          #expect(policy["stale_days"] as? Int == 7)
        }
      }
    }
  }

  @Test func briefRetainsLocationWarningsWithoutHookStderr() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["update-ref", "-d", "refs/remotes/origin/portal"], repo, scratch)
      for flags in [["--json"], ["--hook", "--json", "--verbose"], ["--hook"]] {
        let before = try hookTimeoutCount(scratch)
        let result = try run(flags, repo, scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        // WallClockHookTests checks the hook log without this allowance.
        if flags.contains("--hook"), try hookTimeoutCount(scratch) > before { continue }
        let warnings = try DogfoodLogTests.last(scratch)["warnings"] as? [String]
        if flags.contains("--json") { #expect(result.stdout.contains("ref_missing")) }
        #expect(warnings == ["ref_missing"])
      }
    }
  }
}
