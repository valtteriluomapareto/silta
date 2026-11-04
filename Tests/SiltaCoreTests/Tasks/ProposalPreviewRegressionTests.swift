import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct ProposalPreviewRegressionTests {
  @Test(arguments: ["triage", "ask"], ["", "<unused>"])
  func approvedPreviewPredictsTodoWithoutValidatingWords(policy: String, words: String) async throws
  {
    try await withScratchDirectory { home in
      let env = try ProposalPolicyTests.setup(home, policy: policy)
      let before = try ProposalPolicyTests.snapshot(env)
      var options = TaskImport()
      options.dryRun = true
      options.split = true
      let result = try await TaskService(environment: env, approved: words).fromPlan(
        TaskImportTests.text, options: options, directory: home)
      #expect(result.preview.status == "todo")
      #expect(result.preview.steps.allSatisfy { $0.status == "todo" })
      #expect(!result.approvalUsed && result.tasks.isEmpty)
      #expect(try ProposalPolicyTests.snapshot(env) == before)
    }
  }

  @Test(arguments: [false, true])
  func askPreviewExplainsRequiredConsentAndOutcome(explicit: Bool) async throws {
    try await withScratchDirectory { home in
      let env = try ProposalPolicyTests.setup(home, policy: "ask")
      let before = try ProposalPolicyTests.snapshot(env)
      var options = TaskImport()
      options.dryRun = true
      options.split = true
      let result = try await TaskService(environment: env, workspace: explicit ? "acme" : nil)
        .fromPlan(TaskImportTests.text, options: options, directory: home)
      #expect(result.preview.status == "todo")
      #expect(result.preview.steps.allSatisfy { $0.status == "todo" })
      let warning = try #require(result.warnings.first { $0.code == "proposal_approval_required" })
      #expect(warning.message.contains("human's go-ahead in chat"))
      #expect(warning.message.contains("3 tasks as todo"))
      #expect(try ProposalPolicyTests.snapshot(env) == before)
    }
  }

  @Test(arguments: ["add", "checklist", "split"])
  func refusalNamesTodoAndTaskCount(operation: String) async throws {
    try await withScratchDirectory { home in
      let env = try ProposalPolicyTests.setup(home, policy: "ask")
      let service = TaskService(environment: env)
      do {
        if operation == "add" {
          _ = try await service.add(TaskDraft(title: "Acme"), directory: home)
        } else {
          var options = TaskImport()
          options.split = operation == "split"
          _ = try await service.fromPlan(TaskImportTests.text, options: options, directory: home)
        }
        Issue.record("unapproved creation accepted")
      } catch let error as ActorError {
        #expect(error.message.contains("created as todo"))
        #expect(error.message.contains(operation == "split" ? "3 tasks" : "this task"))
      }
    }
  }

  @Test(arguments: [false, true])
  func unconfiguredPreviewLeavesStorageMissing(approved: Bool) async throws {
    try await withScratchDirectory { home in
      let location = home.appending(path: "missing")
      let env = try TaskServiceTests.environment(location)
      var options = TaskImport()
      options.dryRun = true
      let result = try await TaskService(environment: env, approved: approved ? "<unused>" : nil)
        .fromPlan(TaskImportTests.text, options: options, directory: home)
      #expect(result.preview.status == (approved ? "todo" : "proposed"))
      #expect(result.warnings.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: location.path))
    }
  }

  @Test func unknownStoredProposalPolicyRefusesWithoutWrites() async throws {
    try await withScratchDirectory { home in
      let env = try ProposalPolicyTests.setup(home, policy: "future")
      let before = try ProposalPolicyTests.snapshot(env)
      do {
        _ = try await TaskService(environment: env).add(TaskDraft(title: "Acme"), directory: home)
        Issue.record("unknown proposal policy accepted")
      } catch let error as WorkspaceError {
        #expect(error.code == .invalid)
        #expect(error.message.contains("setting proposals"))
        #expect(error.message.contains("newer silta") && error.message.contains("human"))
        #expect(error.next == ["silta --ws 'acme' ws show"])
      }
      #expect(try ProposalPolicyTests.snapshot(env) == before)
    }
  }
}
