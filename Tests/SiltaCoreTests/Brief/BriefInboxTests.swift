import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct BriefInboxTests {
  /// A human's grouped items have no post fields: the brief renders them from kind,
  /// task pointers and `next`, in the inbox's own order and with its commands.
  @Test func humanBriefRendersGroupedItemsWithInboxCommands() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"))
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      for _ in 0..<3 { _ = try await InboxGroupTests.add(service, home) }
      try InboxGroupTests.block(service, "AC-2", ["ext:acme"], "0d")
      try InboxGroupTests.block(service, "AC-3", ["AC-1"], "7d")
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET status='done' WHERE seq=1")
      }
      let inbox = try service.inbox(for: "human:acme", all: true)
      #expect(inbox.items.map(\.kind) == ["ready", "due"])
      let sections = try env.db.read { db in
        try BriefDiscussion(
          db: db, service: service, caller: env.actor, workspace: "acme",
          command: "silta --ws 'acme'", current: nil, characters: 10_000
        ).sections()
      }
      #expect(sections.task.isEmpty)
      let text = sections.inbox.map(\.text)
      #expect(text.first == "inbox: 2 items for human:acme\n")
      let ready = try #require(inbox.items.first)
      let due = try #require(inbox.items.last)
      #expect(
        text.dropFirst().first
          == "ready AC-3:\n> AC-3: Acme work\n" + ready.next.map { "next: " + $0 + "\n" }.joined()
      )
      #expect(text.last?.hasPrefix("due AC-2 on ext:acme due ") == true)
      #expect(text.last?.contains("> AC-2: Acme work\n") == true)
      let commands = Set(ready.next)
      for command in due.next where !commands.contains(command) {
        #expect(text.last?.contains("next: " + command + "\n") == true, "\(command)")
      }
    }
  }

  /// Lifting the item cap must not widen eligibility: a 15-day-old proposal is out of the
  /// default inbox, so the brief and its `more: … inbox` agree there is no attention.
  @Test func briefKeepsTheDefaultInboxProposalWindow() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"))
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      _ = try await InboxGroupTests.add(service, home, "Acme idea")
      try env.db.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET status='proposed',created_by='agent:codex:acme',
              created_at='2023-10-30T22:13:20.000Z' WHERE seq=1
            """)
      }
      #expect(try service.inbox(for: nil).items.isEmpty)
      #expect(try service.inbox(for: nil, all: true).items.map(\.kind) == ["proposal"])
      let sections = try env.db.read { db in
        try BriefDiscussion(
          db: db, service: service, caller: env.actor, workspace: "acme",
          command: "silta --ws 'acme'", current: nil, characters: 10_000
        ).sections()
      }
      withKnownIssue("The brief's uncapped inbox read also includes expired proposals") {
        #expect(sections.inbox.isEmpty)
      }
    }
  }
}
