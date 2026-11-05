import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

struct SessionFilterTests {
  @Test(arguments: [
    "own", "foreign-claim", "foreign-write", "expired", "expired-at-start", "promoted",
    "review", "no-writes", "claim-only", "created-only", "secret-only", "link", "foreign-comment",
  ])
  func onlyFreshOwnMeaningfulWritesNeedHandoff(kind: String) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      _ = try SessionCheckTests.run(["task", "add", "Acme work", "--start"], in: scratch)
      if !["no-writes", "link", "foreign-comment"].contains(kind) {
        _ = try SessionCheckTests.run(
          ["task", "plan", "AC-1", "-m", "- [ ] Acme next"], in: scratch)
      }
      if kind == "link" {
        _ = try SessionCheckTests.run(
          ["task", "link", "AC-1", "url:https://example.invalid/acme"], in: scratch)
      }
      if kind == "foreign-comment" {
        let other = SessionCheckTests.environment.merging(["SILTA_SESSION": "other"]) { _, new in
          new
        }
        _ = try SessionCheckTests.run(
          ["comment", "AC-1", "-m", "Acme context"], in: scratch, environment: other)
      }
      try store.write { tx in
        var change = "claimed_at='2023-11-14T22:13:20.000Z'"
        if kind == "foreign-claim" { change += ",claimed_by='agent:claude:other'" }
        if kind == "expired" { change = "claimed_at='2023-11-14T20:13:19.999Z'" }
        if kind == "expired-at-start" { change = "claimed_at='2023-11-14T20:13:20.000Z'" }
        if kind == "promoted" { change += ",external_ref='ado:42'" }
        if kind == "review" { change += ",status='review'" }
        try tx.database.execute(sql: "UPDATE task SET " + change)
        if kind == "foreign-write" {
          try tx.database.execute(sql: "UPDATE task_event SET actor='agent:claude:other'")
        }
        let kinds = [
          "claim-only": "claim", "created-only": "created", "secret-only": "secret_redacted",
        ]
        if let event = kinds[kind] {
          try tx.database.execute(sql: "UPDATE task_event SET kind=?", arguments: [event])
        }
      }
      #expect(
        try SessionCheckTests.tasks(in: scratch).count == (["own", "link"].contains(kind) ? 1 : 0))
    }
  }

  @Test func stopSelectionAndSilentFailures() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      _ = try AgentsInstallTests.apply(["install", "--claude", "--stop-hook"], in: scratch)
      let command = try AgentsHookTests.command("Stop", in: scratch)
      for flags in [["--hook"], ["--hook", "--stop-hook"], []] {
        #expect(
          try AgentsInstallTests.apply(["install", "--claude"] + flags, in: scratch).termination
            == .exit(0))
        #expect(try AgentsHookTests.command("Stop", in: scratch) == command)
      }
      for args in [
        ["install", "--codex", "--stop-hook"], ["uninstall", "--claude", "--stop-hook"],
      ] {
        let result = try AgentsInstallTests.run(args + ["--json"], in: scratch)
        #expect(result.termination == .exit(1))
        #expect(try GuideContractTests.object(result.stdout)["ok"] as? Bool == false)
      }
      for payload in [
        "bad", "{}", #"{"session_id":5}"#,
        #"{"session_id":"acme-session","stop_hook_active":"bad"}"#,
        #"{"session_id":"acme-session","stop_hook_active":true}"#,
      ] {
        let result = try AgentsHookTests.hook(command, payload: payload, in: scratch)
        #expect(result.termination == .exit(0) && result.stdout.isEmpty && result.stderr.isEmpty)
      }
    }
  }
}

extension SessionFilterTests {
  @Test func stopReasonIsBoundedAndNormalCheckFindsTheRemainder() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      _ = try AgentsInstallTests.apply(["install", "--claude", "--stop-hook"], in: scratch)
      for index in 1...6 {
        _ = try SessionCheckTests.run(["task", "add", "Acme work", "--start"], in: scratch)
        _ = try SessionCheckTests.run(
          ["task", "plan", "AC-\(index)", "-m", "- [ ] Acme next"], in: scratch)
      }
      let command = try AgentsHookTests.command("Stop", in: scratch)
      let result = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme-session"}"#,
        in: scratch, environment: SessionCheckTests.environment)
      let reason = try #require(try GuideContractTests.object(result.stdout)["reason"] as? String)
      #expect(reason.split(separator: "\n").filter { $0.hasPrefix("silta ") }.count == 5)
      #expect(reason.hasSuffix("More: silta session check"))
      #expect(
        try SessionCheckTests.tasks(in: scratch).map { $0["ref"] } == (1...6).map { "AC-\($0)" })
    }
  }
}
