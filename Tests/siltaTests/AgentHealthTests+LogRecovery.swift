import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

extension AgentHealthTests {
  @Test(arguments: ["malformed", "truncated", "future", "oversized"])
  func invalidEvidenceRecoveryPreservesThenQuarantinesTheDiagnosedLog(_ kind: String) throws {
    withKnownIssue("SI-60/14: invalid evidence has no diagnosed-home recovery") {
      try withScratchDirectory { scratch in
        let env = try Self.setup(scratch)
        let directory = scratch.appending(path: "silta-home/log")
        let day = kind == "future" ? "2026-11-07" : "2026-11-06"
        let file = directory.appending(path: day + ".jsonl")
        let healthy = try Self.healthyHistory()
        let bytes =
          kind == "oversized"
          ? Data(repeating: 65, count: 1_048_577)
          : Data(
            (kind == "malformed"
              ? "{broken\n" + healthy : kind == "truncated" ? String(healthy.dropLast()) : healthy)
              .utf8)
        try bytes.write(to: file)
        let check = try Self.check("install.claude.session", in: Self.checks(scratch, env))
        #expect(check["status"] as? String == "warning")
        #expect(check["next_by"] as? String == "human")
        #expect((check["message"] as? String)?.contains(file.path) == true)
        let next = try #require(check["next"] as? [String])
        let backup = scratch.appending(path: "preserved-evidence")
        let quarantine = scratch.appending(path: "quarantined-evidence")
        let preserve = try #require(next.first { $0.contains("/bin/cp -pR") })
        let move = try #require(next.first { $0.contains("/bin/mv") })
        let retry = try #require(next.last)
        #expect(retry.contains(scratch.appending(path: "silta-home").path))
        #expect(retry.contains("silta doctor --install"))
        for command in [
          preserve.replacingOccurrences(of: "<new-backup-path>", with: backup.path),
          move.replacingOccurrences(of: "<new-quarantine-path>", with: quarantine.path),
        ] {
          let result = try SiltaBinary.runProcess(
            URL(filePath: "/bin/sh"), ["-c", command], in: scratch, environment: env)
          #expect(result.termination == .exit(0), "\(result.stderr)")
        }
        #expect(try Data(contentsOf: backup).starts(with: bytes))
        #expect(try Data(contentsOf: quarantine) == Data(contentsOf: backup))
        try Self.logs(healthy, scratch)
        let result = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", retry], in: scratch, environment: env)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("pass: install.claude.session:"))
      }
    }
  }

  @Test(arguments: [false, true])
  func aggregateLogLimitUsesOtherwiseValidCompleteFiles(_ over: Bool) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let directory = scratch.appending(path: "silta-home/log")
      try FileManager.default.removeItem(at: directory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let now = try #require(utcInstant("2026-11-06T12:00:00.000Z"))
      for offset in 0..<16 {
        let day = utcDay(now.addingTimeInterval(-Double(offset) * 86400))
        let text =
          try offset == 0
          ? Self.healthyHistory()
          : Self.entry("silta guide").replacingOccurrences(of: "2026-11-06", with: day)
        let padding = String(repeating: " ", count: 1_048_576 - text.utf8.count)
        try Data((padding + text).utf8).write(to: directory.appending(path: day + ".jsonl"))
      }
      if over {
        let text = try Self.entry("silta guide").replacingOccurrences(
          of: "2026-11-06", with: "2026-10-21")
        try Data(text.utf8).write(to: directory.appending(path: "2026-10-21.jsonl"))
      }
      let checks = try Self.checks(scratch, env)
      #expect(
        try Self.check("install.claude.session", in: checks)["status"] as? String
          == (over ? "warning" : "pass"))
    }
  }

  @Test(arguments: [false, true])
  func fileCountLimitDiagnosesInventoryBeforeIndividualFiles(_ over: Bool) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let directory = scratch.appending(path: "silta-home/log")
      try FileManager.default.removeItem(at: directory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let now = try #require(utcInstant("2026-11-06T12:00:00.000Z"))
      for offset in 0..<90 {
        let day = utcDay(now.addingTimeInterval(-Double(offset) * 86400))
        let text =
          try offset == 0
          ? Self.healthyHistory()
          : Self.entry("silta guide").replacingOccurrences(of: "2026-11-06", with: day)
        try Data(text.utf8).write(to: directory.appending(path: day + ".jsonl"))
      }
      if over { try Data().write(to: directory.appending(path: "2026-11-07.jsonl")) }
      let check = try Self.check("install.claude.session", in: Self.checks(scratch, env))
      #expect(check["status"] as? String == (over ? "warning" : "pass"))
      if over {
        withKnownIssue("SI-60/14: retained file bound lacks its diagnosis") {
          #expect((check["message"] as? String)?.contains("90-file limit") == true)
          #expect((check["message"] as? String)?.contains(directory.path) == true)
        }
      }
    }
  }

  @Test func openCodeSkillDoesNotFollowClaudeConfigOverride() throws {
    try withScratchDirectory { scratch in
      var env = try Self.setup(scratch)
      let original = scratch.appending(path: "home/.claude")
      let overridden = scratch.appending(path: "effective-claude")
      try FileManager.default.copyItem(at: original, to: overridden)
      env["CLAUDE_CONFIG_DIR"] = overridden.path
      let skill = original.appending(path: "skills/silta/SKILL.md")
      let bytes = try Data(contentsOf: skill)
      try FileManager.default.removeItem(at: skill)
      let missing = try Self.checks(scratch, env)
      #expect(try Self.check("install.skill", in: missing)["status"] as? String == "pass")
      #expect(
        try Self.check("install.opencode.skill", in: missing)["status"] as? String == "warning")
      try bytes.write(to: skill)
      #expect(
        try Self.check("install.opencode.skill", in: Self.checks(scratch, env))["status"] as? String
          == "pass")
    }
  }
}
