import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskPlanReviewRegressionTests {
  static let secretPlan = "- [ ] Ship\nPwd=" + "acme-value"

  static func humanPlan(_ home: URL) async throws -> TaskService {
    let env = try TaskServiceTests.environment(home, actor: TaskServiceTests.human())
    try TaskServiceTests.setup(env)
    let service = TaskService(environment: env)
    _ = try await service.add(TaskDraft(title: "Acme"), directory: home)
    _ = try service.plan("AC-1", text: secretPlan, allowSecret: true)
    return service
  }

  // A tick adds no text, so the secret guard leaves a stored plan as the human kept it.
  @Test func agentTicksKeepStoredPlans() async throws {
    try await withScratchDirectory { home in
      _ = try await Self.humanPlan(home)
      let env = try TaskServiceTests.environment(home)
      let service = TaskService(environment: env)
      let result = try service.tick("AC-1", step: 1, done: true)
      #expect(result.plan == Self.secretPlan.replacingOccurrences(of: "[ ]", with: "[x]"))
      #expect(result.warnings.isEmpty)
      #expect(try service.show("AC-1").plan == result.plan)
      #expect(try service.show("AC-1", timeline: true).timeline?.last?.kind == "step")
      #expect(result.planRev == 1)
      #expect(
        try env.db.read { try String.fetchAll($0, sql: "SELECT body_md FROM task_plan_rev") } == [
          Self.secretPlan
        ])
    }
  }

  @Test func secretRetryRetainsCASAfterAnotherRevisionArrives() async throws {
    try await withScratchDirectory { home in
      let service = try await Self.humanPlan(home)
      var retry = ""
      do {
        _ = try service.plan("AC-1", text: Self.secretPlan, ifRevision: 1)
        Issue.record("Human replacement accepted secret")
      } catch let error as SecretError {
        retry = try #require(error.next.first)
        #expect(retry == "silta task plan 'AC-1' --if-rev 1 -F <file> --allow-secret")
      }
      _ = try service.plan("AC-1", text: "- [ ] Newer", ifRevision: 1)
      let expected = retry.split(separator: " ").drop(while: { $0 != "--if-rev" })
        .dropFirst().first.flatMap { Int($0) }
      #expect(throws: TaskError.staleRev("AC-1", actual: 2)) {
        _ = try service.plan("AC-1", text: Self.secretPlan, ifRevision: expected, allowSecret: true)
      }
      #expect(try service.show("AC-1").plan == "- [ ] Newer")
    }
  }

  @Test(arguments: ["    ", "\t", " \t"])
  func indentedFenceExamplesDoNotHideRealSteps(indentation: String) throws {
    let source = "# Acme\n\(indentation)```\n\n- Real step\n"
    #expect(try MarkdownPlan(source).steps.map(\.title) == ["Real step"])
    let checklist = "\(indentation)```\n\n- [ ] Real step"
    #expect(
      try MarkdownPlan.tick(checklist, step: 1, done: true)
        == "\(indentation)```\n\n- [x] Real step")
  }
}

extension TaskPlanReviewRegressionTests {
  @Test func humanTickRetainsPlanAndImmutableSnapshot() async throws {
    try await withScratchDirectory { home in
      let service = try await Self.humanPlan(home)
      let result = try service.tick("AC-1", step: 1, done: true, ifRevision: 1)
      #expect(result.plan == Self.secretPlan.replacingOccurrences(of: "[ ]", with: "[x]"))
      #expect(result.planRev == 1 && result.warnings.isEmpty)
      let env = try TaskServiceTests.environment(home)
      #expect(throws: TaskError.staleRev("AC-1", actual: 1)) {
        _ = try TaskService(environment: env).tick("AC-1", step: 1, done: false, ifRevision: 0)
      }
      #expect(try service.show("AC-1").plan == result.plan)
      #expect(
        try env.db.read { try String.fetchAll($0, sql: "SELECT body_md FROM task_plan_rev") } == [
          Self.secretPlan
        ])
    }
  }
}
