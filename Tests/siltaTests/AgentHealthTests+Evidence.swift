import CryptoKit
import Foundation
import GRDB
import SiltaTestSupport
import Testing

extension AgentHealthTests {
  @Test(arguments: [
    "truncated", "oversized", "symlink", "directory", "foreign-name", "equal-time", "hook-only",
    "unrelated",
  ])
  func retainedEvidenceCannotHideDamage(_ fault: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      var log = try Self.entry("silta agents session-start")
      log += try Self.entry(
        "silta task ls", time: fault == "equal-time" ? "10:00:00" : "10:01:00", propagated: true)
      if fault == "truncated" { log.removeLast() }
      if fault == "hook-only" {
        log = try Self.entry("silta agents session-start", propagated: true)
      }
      if fault == "unrelated" {
        log =
          try Self.entry("silta agents session-start")
          + Self.entry("silta task ls", session: "other", time: "10:01:00", propagated: true)
      }
      try Self.logs(log, scratch)
      let file = scratch.appending(path: "silta-home/log/2026-11-06.jsonl")
      if fault == "oversized" { try Data(repeating: 65, count: 1_048_577).write(to: file) }
      if fault == "foreign-name" {
        try Data("broken".utf8).write(
          to: file.deletingLastPathComponent().appending(path: "notes.jsonl"))
      }
      if fault == "symlink" || fault == "directory" {
        try FileManager.default.removeItem(at: file)
        if fault == "symlink" {
          let outside = scratch.appending(path: "outside")
          try Data(log.utf8).write(to: outside)
          try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        } else {
          try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
      }
      let checks = try Self.checks(scratch, env)
      let session = try Self.check("install.claude.session", in: checks)
      #expect(
        (session["status"] as? String == "pass") == ["foreign-name", "equal-time"].contains(fault))
      if ["truncated", "oversized", "symlink", "directory"].contains(fault) {
        #expect(
          try Self.check("install.claude.session_start", in: checks)["status"] as? String
            == "warning")
      }
    }
  }

  @Test(arguments: ["duplicate", "stale", "foreign", "settings", "foreign-root"])
  func ownershipUsesCurrentContentAndPreservesForeignBytes(_ fault: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let path =
        fault == "settings"
        ? ".claude/settings.json"
        : fault == "foreign-root" ? ".codex/config.toml" : ".codex/AGENTS.md"
      let old = try AgentsInstallTests.read(path, in: scratch)
      var text = old
      switch fault {
      case "duplicate": text += old
      case "foreign": text = "Acme private sentinel\n" + old + "\nOther instruction\n"
      case "settings": text = "{broken"
      case "foreign-root":
        text = old.replacingOccurrences(
          of: "writable_roots = [", with: "writable_roots = [\"/Acme/other\", ")
      default:
        let range = try #require(old.range(of: "\n<!-- silta:begin "))
        let finish = try #require(old.range(of: "<!-- silta:end -->\n"))
        let body = "Old but sealed Acme instructions\n"
        let input = Data(("new:" + body).utf8)
        // A known seal for fixed text is computed in the test, independently of production.
        text =
          String(old[..<range.lowerBound]) + "\n<!-- silta:begin "
          + SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined() + ":new -->\n"
          + body + String(old[finish.lowerBound...])
      }
      try AgentsInstallTests.write(text, path, in: scratch)
      let checks = try Self.checks(scratch, env)
      let id =
        fault == "settings"
        ? "install.hook"
        : fault == "foreign-root" ? "install.codex_root" : "install.codex.instructions"
      #expect(
        (try Self.check(id, in: checks)["status"] as? String == "pass")
          == ["foreign", "foreign-root"].contains(fault))
      #expect(try AgentsInstallTests.read(path, in: scratch) == text)
      #expect(!String(describing: checks).contains("Acme private sentinel"))
    }
  }

  @Test func doctorOnlyAppendsLogAndDoesNotPruneOrInitialize() throws {
    try withScratchDirectory { scratch in
      let directory = scratch.appending(path: "silta-home/log")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let old = directory.appending(path: "2020-01-01.jsonl")
      try Data("Acme old log\n".utf8).write(to: old)
      let result = try SiltaBinary.run(["doctor", "--json"], in: scratch, environment: Self.now)
      #expect(result.termination == .exit(9))
      #expect(try String(contentsOf: old, encoding: .utf8) == "Acme old log\n")
      let names = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "silta-home").path)
      #expect(names == ["log"])
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: scratch.appending(path: "home").path)
          .isEmpty)
    }
  }

  @Test(arguments: ["missing", "wrapper", "nonexecutable", "unrelated"])
  func unknownVersionIsHumanOwnedAndDoesNotLaunch(_ fault: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let bin = scratch.appending(path: "bin/codex")
      let native = scratch.appending(path: "Caskroom/codex/0.166.0/bin/codex")
      if fault == "missing" { try FileManager.default.removeItem(at: bin) }
      if fault == "nonexecutable" {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: native.path)
      }
      if fault == "wrapper" || fault == "unrelated" {
        try FileManager.default.removeItem(at: bin)
        try FileManager.default.copyItem(at: native, to: bin)
      }
      let check = try Self.check("install.codex.version", in: Self.checks(scratch, env))
      #expect(check["status"] as? String == "warning")
      #expect(check["next_by"] as? String == "human")
      #expect(check["next"] as? [String] == ["codex --version"])
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "launched").path))
    }
  }
}

extension AgentHealthTests {
  @Test(arguments: ["matching", "absent", "overridden"])
  func propagationLogUsesOriginalShellAndResolvedSession(_ kind: String) throws {
    try withScratchDirectory { scratch in
      let secret = "AcmeUnloggedSession"
      var env = Self.now.merging(["SILTA_ACTOR": "agent:claude:one"]) { _, new in new }
      if kind != "absent" { env["SILTA_SESSION"] = kind == "matching" ? "one" : secret }
      _ = try SiltaBinary.run(["guide"], in: scratch, environment: env)
      let text = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2026-11-06.jsonl"), encoding: .utf8)
      let entry = try GuideContractTests.object(text)
      #expect(entry["session_matches_actor"] as? Bool == (kind == "matching"))
      #expect(!text.contains(secret))
      let exported = scratch.appending(path: "exported")
      let hook = try AgentsHookTests.hook(
        "silta agents session-start", payload: #"{"session_id":"one"}"#, in: scratch,
        environment: Self.now.merging(["CLAUDE_ENV_FILE": exported.path]) { _, new in new })
      #expect(hook.termination == .exit(0))
      let log = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2026-11-06.jsonl"), encoding: .utf8)
      let lines = log.split(separator: "\n")
      let last = try GuideContractTests.object(String(try #require(lines.last)))
      #expect(last["command"] as? String == "silta agents session-start")
      #expect(last["session_matches_actor"] == nil)
    }
  }
  @Test func initializedHomeIsUnchangedExceptForCommandLogAppend() throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let home = scratch.appending(path: "silta-home")
      let before = try snapshot(home).filter { !$0.key.contains("/log/") }
      let checks = try Self.checks(scratch, env)
      #expect(checks.allSatisfy { ($0["id"] as? String)?.hasPrefix("install.") == true })
      let after = try snapshot(home).filter { !$0.key.contains("/log/") }
      let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
      #expect(
        after == before, "Changed files: \(changed.map { URL(filePath: $0).lastPathComponent })")
    }
  }

}

extension AgentHealthTests {
  @Test(arguments: ["missing", "corrupt", "locked"])
  func focusedHealthBypassesAllDatabaseAccess(_ kind: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let home = scratch.appending(path: "silta-home")
      let file = home.appending(path: "silta.db")
      if kind == "missing" { try FileManager.default.removeItem(at: file) }
      if kind == "corrupt" { try Data("Acme invalid SQLite".utf8).write(to: file) }
      func inspect() throws {
        let before = try snapshot(home).filter { !$0.key.contains("/log/") }
        for flags in [["--json"], ["--quiet"]] {
          let result = try SiltaBinary.run(
            ["doctor", "--install"] + flags, in: scratch, environment: env)
          #expect(result.termination == .exit(0))
          #expect(result.stderr.isEmpty)
          #expect(try snapshot(home).filter { !$0.key.contains("/log/") } == before)
        }
      }
      if kind == "locked" {
        let queue = try DatabaseQueue(path: file.path)
        try queue.writeWithoutTransaction { db in
          try db.execute(sql: "BEGIN EXCLUSIVE")
          defer { try? db.execute(sql: "ROLLBACK") }  // best-effort test lock cleanup
          try inspect()
        }
      } else {
        try inspect()
      }
    }
  }
}

extension AgentHealthTests {
  @Test func populatedOverridesAreInspectedIndependently() throws {
    try withScratchDirectory { scratch in
      var env = try Self.setup(scratch)
      for (key, name) in [("CLAUDE_CONFIG_DIR", ".claude"), ("CODEX_HOME", ".codex")] {
        let path = scratch.appending(path: "effective-" + name)
        try FileManager.default.copyItem(at: scratch.appending(path: "home/" + name), to: path)
        env[key] = path.path
      }
      let checks = try Self.checks(scratch, env)
      for id in [
        "install.skill", "install.hook", "install.codex_root", "install.codex.instructions",
      ] {
        #expect(try Self.check(id, in: checks)["status"] as? String == "pass")
      }
      try Data("\n<!-- silta:begin broken -->\n".utf8).write(
        to: scratch.appending(path: "effective-.codex/AGENTS.md"))
      let damaged = try Self.checks(scratch, env)
      #expect(
        try Self.check("install.codex.instructions", in: damaged)["status"] as? String == "fail")
      #expect(try Self.check("install.hook", in: damaged)["status"] as? String == "pass")
      #expect(try Self.check("install.codex_root", in: damaged)["status"] as? String == "pass")
    }
  }
}
