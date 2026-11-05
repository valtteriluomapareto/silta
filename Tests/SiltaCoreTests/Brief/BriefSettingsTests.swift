import Foundation
@testable import SiltaCore
import Testing

struct BriefSettingsTests {
  @Test func manyUnsupportedKeysKeepValidSettingsAndBoundHint() throws {
    var values: [String: Any] = ["proposals": "ask"]
    for index in 1...20 {
      values["\(index)-" + String(repeating: "future", count: 80)] = String(
        repeating: "x", count: 400)
    }
    let settings = BriefSettings(
      WorkspaceSettings(workspace: "acme", json: try WorkspaceConfig.json(values)),
      workspace: "acme")
    #expect(settings.proposals == "ask")
    #expect(settings.warnings.count == 20)
    #expect(settings.warnings.allSatisfy { $0.message.count < 300 })
    let hint = try #require(settings.text.split(separator: "\n").last)
    #expect(hint.count < 420)
    #expect(hint.contains("ask the human"))
    #expect(hint.contains("+12 keys"))
  }
}
