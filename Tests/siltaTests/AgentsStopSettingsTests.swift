import Foundation
import SiltaTestSupport
import Testing

struct AgentsStopSettingsTests {
  @Test(arguments: [nil, "{}", #"{"hooks":{}}"#, #"{"hooks":{"SessionStart":[],"Stop":[]}}"#])
  func addingStopLaterRetainsContainerProvenance(original: String?) throws {
    try withScratchDirectory { scratch in
      if let original {
        try AgentsInstallTests.write(original, ".claude/settings.json", in: scratch)
      }
      for flags in [["--hook"], ["--stop-hook"]] {
        #expect(
          try AgentsInstallTests.apply(["install", "--claude"] + flags, in: scratch).termination
            == .exit(0))
      }
      #expect(try AgentsHookTests.command("Stop", in: scratch).contains("agents stop"))
      _ = try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch)
      let file = scratch.appending(path: "home/.claude/settings.json")
      if let original {
        let restored = try String(contentsOf: file, encoding: .utf8)
        #expect(
          try GuideContractTests.object(restored) as NSDictionary == GuideContractTests.object(
            original) as NSDictionary)
      } else {
        #expect(!FileManager.default.fileExists(atPath: file.path))
      }
    }
  }

  @Test(arguments: ["edit", "duplicate", "mixed"])
  func stopOwnershipRefusesBeforeOtherWrites(kind: String) throws {
    try withScratchDirectory { scratch in
      _ = try AgentsInstallTests.apply(["install", "--claude", "--stop-hook"], in: scratch)
      let text = try AgentsInstallTests.read(".claude/settings.json", in: scratch)
      var root = try GuideContractTests.object(text)
      var hooks = try #require(root["hooks"] as? [String: Any])
      var groups = try #require(hooks["Stop"] as? [[String: Any]])
      var handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
      if kind == "edit" { handlers[0]["timeout"] = 3 }
      if kind == "mixed" { handlers.append(["type": "command", "command": "echo Acme"]) }
      groups[0]["hooks"] = handlers
      if kind == "duplicate" { groups.append(groups[0]) }
      hooks["Stop"] = groups
      root["hooks"] = hooks
      let data = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
      try data.write(to: scratch.appending(path: "home/.claude/settings.json"))
      for operation in ["install", "uninstall"] {
        let flags = operation == "install" ? ["--stop-hook"] : []
        let result = try AgentsInstallTests.run([operation, "--json"] + flags, in: scratch)
        #expect(result.termination == .exit(6))
        #expect(
          try AgentsInstallTests.read(".claude/settings.json", in: scratch)
            == String(data: data, encoding: .utf8))
        #expect(
          !FileManager.default.fileExists(
            atPath: scratch.appending(path: "home/.codex/AGENTS.md").path))
      }
    }
  }
}

extension AgentsStopSettingsTests {
  @Test(arguments: [false, true], ["Stop", "SessionStart"])
  func userEventAddedBetweenHookInstallsSurvives(existingFile: Bool, event: String) throws {
    try withScratchDirectory { scratch in
      if existingFile { try AgentsInstallTests.write("{}", ".claude/settings.json", in: scratch) }
      let first = event == "Stop" ? "--hook" : "--stop-hook"
      let second = event == "Stop" ? "--stop-hook" : "--hook"
      _ = try AgentsInstallTests.apply(["install", "--claude", first], in: scratch)
      var settings = try GuideContractTests.object(
        AgentsInstallTests.read(".claude/settings.json", in: scratch))
      var hooks = try #require(settings["hooks"] as? [String: Any])
      hooks[event] = [Any]()
      settings["hooks"] = hooks
      let file = scratch.appending(path: "home/.claude/settings.json")
      try JSONSerialization.data(withJSONObject: settings, options: .sortedKeys).write(to: file)
      _ = try AgentsInstallTests.apply(["install", "--claude", second], in: scratch)
      _ = try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch)
      let text =
        FileManager.default.fileExists(atPath: file.path)
        ? try String(contentsOf: file, encoding: .utf8) : "{}"
      let restored = try GuideContractTests.object(text) as NSDictionary
      let expected: NSDictionary = ["hooks": [event: [Any]()]]
      #expect(restored == expected)
    }
  }
}
