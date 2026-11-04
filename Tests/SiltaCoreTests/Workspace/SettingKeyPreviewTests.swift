import Foundation
@testable import SiltaCore
import Testing

struct SettingKeyPreviewTests {
  @Test(arguments: [false, true])
  func maskedKeyCollisionsAreSafeAndDeterministic(token: Bool) throws {
    let first = token ? "ghp_" + String(repeating: "a", count: 36) : "Pwd=acme-secret"
    let second = token ? "ghp_" + String(repeating: "b", count: 36) : "Pwd=acme-other"
    let json = try WorkspaceConfig.json(["review_gate": [first: "one", second: "two"]])
    withKnownIssue("#13: secret-bearing keys and redaction collisions") {
      do {
        _ = try WorkspaceSettings(workspace: "acme", json: json).reviewGate
        Issue.record("invalid setting accepted")
      } catch let error as WorkspaceError {
        #expect(!error.message.contains(first))
        #expect(!error.message.contains(second))
        let rule = token ? "github_pat" : "password"
        #expect(error.message.contains("{\"[REDACTED:\(rule)]\":\"[REDACTED:duplicate-key]\"}"))
      }
    }
  }
}
