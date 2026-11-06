import SiltaTestSupport
import Testing

extension AgentHealthTests {
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
