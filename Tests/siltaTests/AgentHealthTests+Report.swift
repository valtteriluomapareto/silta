import SiltaTestSupport
import Testing

extension AgentHealthTests {
  @Test func installedSessionStartDoesNotRequireAnUninstalledStop() throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch, stop: false)
      let checks = try Self.checks(scratch, env)
      #expect(try Self.check("install.hook", in: checks)["status"] as? String == "pass")
      #expect(try Self.check("install.claude.stop", in: checks)["status"] as? String == "skipped")
      #expect(
        try Self.check("install.claude.session_start", in: checks)["status"] as? String == "warning"
      )
      let stop = try Self.check("install.claude.last_stop", in: checks)
      #expect(stop["status"] as? String == "skipped")
      #expect(stop["next"] as? [String] == [])
      try Self.logs(Self.healthyHistory(), scratch)
      let later = try Self.checks(scratch, env)
      #expect(
        try Self.check("install.claude.last_stop", in: later)["status"] as? String == "skipped")
      #expect(try Self.check("install.claude.session", in: later)["status"] as? String == "pass")
    }
  }

  @Test func installMessagesNeverRepeatTheCheckID() throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let checks = try Self.checks(scratch, env)
      for check in checks where (check["id"] as? String)?.hasPrefix("install.") == true {
        let id = try #require(check["id"] as? String)
        let message = try #require(check["message"] as? String)
        #expect(!message.hasPrefix(id + ":"), "\(id): \(message)")
      }
    }
  }

  @Test func unsupportedHarnessesReportOneSkippedHooksRow() throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let checks = try Self.checks(scratch, env)
      for id in ["install.codex.hooks", "install.opencode.hooks"] {
        let row = try Self.check(id, in: checks)
        #expect(row["status"] as? String == "skipped", "\(id)")
        #expect(row["next"] as? [String] == [], "\(id)")
      }
      let unsupported = checks.filter {
        ($0["message"] as? String)?.contains("no Silta hook integration") == true
      }
      #expect(unsupported.count == 2)
      #expect(
        Set(unsupported.compactMap { $0["id"] as? String })
          == ["install.codex.hooks", "install.opencode.hooks"])
    }
  }
}
