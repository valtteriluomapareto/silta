import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// Refusals that name what they refer to and point at a command the caller can run.
@Suite(.timeLimit(.minutes(1)))
struct TaskOutputRegressionTests {
  private static func json(_ error: any CodedError) throws -> [String: Any] {
    let line = OutputRouter.render(.failure(error), mode: OutputMode(json: true)).stdout
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    return try #require(object["error"] as? [String: Any])
  }

  @Test func notFoundNamesTheRefAndItsRole() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, directory: home)
      let missing = #expect(throws: TaskError.self) { _ = try service.show("AC-9") }
      var parent = TaskDraft(title: "Acme child")
      parent.parent = "AC-9"
      let orphan = await #expect(throws: TaskError.self) {
        _ = try await service.add(parent, directory: home)
      }
      let blocker = #expect(throws: TaskError.self) {
        _ = try service.block("AC-1", TaskBlockTests.input(["AC-9"]))
      }
      #expect(missing?.message == "Task AC-9 not found.")
      #expect(orphan?.message == "Parent task AC-9 not found.")
      #expect(blocker?.message == "Blocker task AC-9 not found.")
    }
  }

  @Test func claimedPointsAtOtherWork() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, directory: home)
      let rival = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "codex", session: "rival")))
      let refusal = #expect(throws: TaskError.self) { _ = try rival.archive("AC-1") }
      #expect(refusal?.next == ["silta task ls --status todo"])
      #expect(refusal?.message.contains("ask the human before stealing") == true)
    }
  }

  @Test func notReadyNamesWhatEachTaskWaitsOn() async throws {
    try await withScratchDirectory { home in
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      try TaskServiceTests.setup(human.environment)
      for _ in 0..<2 { _ = try await human.add(TaskDraft(title: "Acme"), directory: home) }
      _ = try human.block("AC-1", TaskBlockTests.input(["ext:acme"]))
      _ = try human.block("AC-2", TaskBlockTests.input())
      let agent = TaskService(environment: try TaskServiceTests.environment(home))
      let refusal = #expect(throws: ActorError.self) { _ = try agent.unblock(["AC-1", "AC-2"]) }
      #expect(
        refusal?.message.hasPrefix("AC-1 waits on ext:acme and AC-2 waits on an answer;")
          == true)
    }
  }

  @Test func blockedPromotionPointsAtUnblockOnlyWhenReady() async throws {
    try await withScratchDirectory { home in
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      try TaskServiceTests.setup(human.environment)
      for _ in 0..<2 { _ = try await human.add(TaskDraft(title: "Acme"), directory: home) }
      _ = try human.block("AC-2", TaskBlockTests.input(["AC-1"]))
      let open = #expect(throws: TaskError.self) {
        _ = try human.promote("AC-2", external: "ado:42")
      }
      #expect(open?.next == ["silta task show AC-2"])
      _ = try await human.close("AC-1", result: "Done", directory: home)
      let ready = #expect(throws: TaskError.self) {
        _ = try human.promote("AC-2", external: "ado:42")
      }
      #expect(ready?.next == ["silta task unblock AC-2"])
    }
  }

  @Test func aHumanRefusedOnAProposalRunsTriageThemselves() async throws {
    try await withScratchDirectory { home in
      let agent = TaskService(environment: try TaskServiceTests.environment(home))
      try TaskServiceTests.setup(agent.environment)
      _ = try await agent.add(TaskDraft(title: "Acme idea"), directory: home)
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      let refusal = await #expect(throws: TaskError.self) {
        _ = try await human.start("AC-1", directory: home)
      }
      let error = try Self.json(try #require(refusal))
      #expect(error["next"] as? [String] == ["silta task triage --accept AC-1"])
      #expect(error["next_by"] as? String == "agent")
    }
  }

  @Test func aStepOnAPlanWithoutCheckboxesSaysHowToWriteThem() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, directory: home)
      _ = try service.plan("AC-1", text: "- First\n- Second")
      let refusal = #expect(throws: TaskError.self) {
        _ = try service.tick("AC-1", step: 1, done: true)
      }
      #expect(refusal?.code == .invalid)
      #expect(refusal?.message.contains("0 checkboxes") == true)
      #expect(refusal?.message.contains("- [ ]") == true)
      #expect(refusal?.next == ["silta task plan AC-1 -F -"])
    }
  }

  @Test func timelineShowsTaskRefsForBlockers() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, count: 2, directory: home)
      _ = try service.block("AC-2", TaskBlockTests.input(["AC-1", "ext:acme"]))
      let timeline = try #require(try service.show("AC-2", timeline: true).timeline)
      let block = try #require(timeline.first { $0.kind == "block" }?.body)
      #expect(block.contains("\"task:AC-1\""))
      #expect(block.contains("\"ext:acme\""))
    }
  }

  @Test func anUnknownWorkspaceIsNamed() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      let unknown = TaskService(environment: service.environment, workspace: "acme-two")
      let refusal = #expect(throws: WorkspaceError.self) { _ = try unknown.list() }
      #expect(refusal?.code == .notFound)
      #expect(refusal?.message.contains("acme-two") == true)
    }
  }
}
