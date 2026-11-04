import Foundation
@testable import SiltaCore
import Testing

struct SettingPreviewTests {
  @Test(arguments: [
    (
      "{\"review_gate\":{\"password\":\"acme-secret\"}}",
      "{\"password\":\"[REDACTED:password]\"}"
    ),
    ("{\"review_gate\":[\"Pwd=acme-secret\"]}", "[\"[REDACTED:password]\"]"),
    (
      "{\"review_gate\":{\"nested\":{\"password\":\"acme-secret\"}}}",
      "{\"nested\":{\"password\":\"[REDACTED:password]\"}}"
    ),
  ])
  func structuredPreviewsStayMaskedAndBalanced(json: String, preview: String) throws {
    withKnownIssue("#13: stored settings previews and policy guidance") {
      do {
        _ = try WorkspaceSettings(workspace: "acme", json: json).reviewGate
        Issue.record("invalid gate accepted")
      } catch let error as WorkspaceError {
        #expect(
          error.message == "Workspace acme setting review_gate has invalid stored value \(preview)."
        )
        #expect(!error.message.contains("acme-secret"))
      }
    }
  }

  @Test(arguments: ["null", "1.5", "[]", "{\"password\":\"acme-secret\""])
  func corruptWholeDocumentNamesSettingsAndHidesSecrets(json: String) throws {
    withKnownIssue("#13: stored settings previews and policy guidance") {
      do {
        _ = try WorkspaceSettings(workspace: "acme", json: json).archiveAfterDays
        Issue.record("invalid settings accepted")
      } catch let error as WorkspaceError {
        #expect(error.message.contains("setting settings "))
        #expect(!error.message.contains("acme-secret"))
        #expect(error.next == ["silta --ws 'acme' ws show"])
      }
    }
  }

  @Test func unknownStoredGateWarnsAboutNewerWriters() throws {
    withKnownIssue("#13: stored settings previews and policy guidance") {
      do {
        _ = try WorkspaceSettings(workspace: "acme", json: "{\"review_gate\":\"future\"}")
          .reviewGate
        Issue.record("unknown gate accepted")
      } catch let error as WorkspaceError {
        #expect(error.message.contains("newer silta"))
        #expect(error.message.contains("human"))
        #expect(error.next == ["silta --ws 'acme' ws show"])
      }
    }
  }

  @Test(arguments: ["robot", "humna"])
  func unknownYamlGateLeavesPolicyChoiceToHuman(word: String) throws {
    withKnownIssue("#13: stored settings previews and policy guidance") {
      do {
        _ = try WorkspaceConfig.parse(
          WorkspaceConfigTests.minimal + "settings: {review_gate: '\(word)'}")
        Issue.record("unknown gate accepted")
      } catch let error as WorkspaceError {
        #expect(error.message.contains("Ask the human"))
      }
    }
  }
}
