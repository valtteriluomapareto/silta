import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocLineDiffTests {
  @Test(arguments: [false, true])
  func longBodySmallChangeHasOneSmallHunk(append: Bool) async throws {
    try await withScratchDirectory { home in
      var old = (1...1500).map { "Line \($0)" }
      old[0] = "# Acme rules"
      var new = old
      if append { new.append("New tail") } else { new[749] = "Changed middle" }
      let store = try await fixture(
        home, old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
      let output = try DocService(workspace: "acme", store: store).show("doc:rules@2", diff: true)
        .output
      #expect(output.contains("why:"))
      #expect(output.contains(append ? "+New tail\n" : "-Line 750\n+Changed middle\n"))
      #expect(output.components(separatedBy: "\n").count < 60)
      #expect(output.contains(append ? "@@ -1498,3 +1498,4 @@" : "@@ -747,7 +747,7 @@"))
      #expect(!output.contains("-# Acme rules") && !output.contains("+# Acme rules"))
    }
  }

  @Test(arguments: [false, true])
  func nearbyChangesMergeAndDistantChangesSeparate(distant: Bool) async throws {
    try await withScratchDirectory { home in
      let old = (1...1500).map { "Line \($0)" }
      var new = old
      new[99] = "First change"
      new[distant ? 1299 : 103] = "Second change"
      let store = try await fixture(
        home, old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
      let output = try DocService(workspace: "acme", store: store).show("doc:rules@2", diff: true)
        .output
      #expect(output.contains("+First change\n") && output.contains("+Second change\n"))
      #expect(output.components(separatedBy: "\n").count < 80)
      #expect(
        output.components(separatedBy: "\n").filter { $0.hasPrefix("@@ ") }.count
          == (distant ? 2 : 1))
    }
  }

  struct Change: Sendable {
    let old: String
    let new: String
    let hunk: String
  }

  @Test(arguments: [
    Change(old: "A\nB", new: "New\nA\nB", hunk: "@@ -1,2 +1,3 @@"),
    Change(old: "A\nB", new: "A\nB\nNew", hunk: "@@ -1,2 +1,3 @@"),
    Change(old: "A\nB", new: "A", hunk: "@@ -1,2 +1,1 @@"),
    Change(old: "", new: "A", hunk: "@@ -0,0 +1,1 @@"),
    Change(old: "A", new: "A\n", hunk: "@@ -1,1 +1,2 @@"),
    Change(old: "é", new: "e\u{301}", hunk: "@@ -1,1 +1,1 @@"),
    Change(old: "A\nR\nR\nB", new: "A\nR\nB", hunk: "@@ -1,4 +1,3 @@"),
  ])
  func shortEditsUseBodyCoordinates(change: Change) async throws {
    try await withScratchDirectory { home in
      let store = try await fixture(home, old: change.old, new: change.new)
      let output = try DocService(workspace: "acme", store: store).show("doc:rules@2", diff: true)
        .output
      #expect(output.contains(change.hunk))
    }
  }

  @Test func metadataOnlyChangeHasNoBodyHunk() async throws {
    try await withScratchDirectory { home in
      let store = try await fixture(
        home, old: "Same body", new: "Same body", title: "Refined rules")
      let output = try DocService(workspace: "acme", store: store).show("doc:rules@2", diff: true)
        .output
      #expect(
        output.contains("Review.") && !output.contains("-Same body")
          && !output.contains("+Same body"))
      #expect(!output.contains("@@ "))
      #expect(output.contains("Refined rules"))
    }
  }

  @Test(arguments: ["rebound", "reordered", "unknown"])
  func knownIdentityChangesStayVisibleWithoutInventingHistory(mode: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let writer = try DocWritePolicyTests.service(home, store)
      _ = try await writer.edit(
        DocEditRequest(slug: "rules", title: "Rules", about: ["service:push", "topic:messaging"]),
        input: { "Same body" })
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET message='Review.'")
        if mode == "rebound" {
          try $0.database.execute(sql: "UPDATE service SET uid='replacement-service'")
        }
        if mode == "unknown" {
          try $0.database.execute(sql: "UPDATE doc_rev SET about_targets=NULL")
        }
      }
      _ = try DocProposalService(environment: writer.environment, workspace: "acme").propose(
        DocProposalRequest(slug: "rules", title: "Proposed rules", why: "Review."),
        input: { "Same body" })
      if mode == "reordered" {
        let raw = try #require(
          try store.read {
            try String.fetchOne($0, sql: "SELECT about_targets FROM doc_rev WHERE rev=2")
          })
        let identities = try JSONDecoder().decode([DocTargetIdentity].self, from: Data(raw.utf8))
        let reversed = try DocTargetIdentity.encoded(Array(identities.reversed()))
        try store.write {
          try $0.database.execute(
            sql: "UPDATE doc_rev SET about_targets=? WHERE rev=2", arguments: [reversed])
        }
      }
      let before = try store.read {
        try String.fetchOne($0, sql: "SELECT about_targets FROM doc_rev WHERE rev=1")
      }
      let output = try DocService(workspace: "acme", store: store).show("doc:rules@2", diff: true)
        .output
      if mode == "rebound" {
        #expect(output.contains("attachment identities: changed"))
        #expect(!output.contains("no visible changes"))
      } else {
        #expect(!output.contains("attachment identities: changed"))
      }
      #expect(!output.contains("replacement-service"))
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT about_targets FROM doc_rev WHERE rev=1")
        } == before)
      if mode == "unknown" { #expect(before == nil) }
    }
  }

  @Test(arguments: [false, true])
  func fallbackPreservesEveryChangedLineAndContext(contextual: Bool) async throws {
    try await withScratchDirectory { home in
      let prefix = contextual ? (1...8).map { "Prefix \($0)" } : []
      let suffix = contextual ? (1...8).map { "Suffix \($0)" } : []
      let removed = (1...1100).map { "Old \($0)" }
      let added = (1...1100).map { "New \($0)" }
      let store = try await fixture(
        home, old: (prefix + removed + suffix).joined(separator: "\n"),
        new: (prefix + added + suffix).joined(separator: "\n"))
      let output = try store.read { db in
        try DocDiff.render(
          DocStore.revision("rules", revision: 2, workspace: 1, in: db),
          base: DocStore.revision("rules", revision: 1, workspace: 1, in: db))
      }
      let lines = output.components(separatedBy: "\n")
      #expect(
        lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("--- ") }
          .map { String($0.dropFirst()) } == removed)
      #expect(
        lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++ ") }
          .map { String($0.dropFirst()) } == added)
      #expect(output.contains(contextual ? "@@ -6,1106 +6,1106 @@" : "@@ -1,1100 +1,1100 @@"))
      if contextual {
        #expect(output.contains(" Prefix 6\n Prefix 7\n Prefix 8\n"))
        #expect(output.contains(" Suffix 1\n Suffix 2\n Suffix 3\n"))
      }
    }
  }

  @Test func mixedEditsKeepLiteralContextAndChanges() async throws {
    try await withScratchDirectory { home in
      let store = try await fixture(
        home, old: "A\nsame1\nsame2\nB", new: "Changed A\nsame1\nAdded\nsame2\nChanged B")
      let output = try DocService(workspace: "acme", store: store).show("doc:rules@2", diff: true)
        .output
      #expect(output.contains("@@ -1,4 +1,5 @@"))
      #expect(output.contains("-A\n+Changed A\n same1\n+Added\n same2\n-B\n+Changed B\n"))
    }
  }

  private func fixture(_ home: URL, old: String, new: String, title: String? = nil) async throws
    -> DatabaseStore
  {
    let store = try AcmeDocAttachments.make(in: home)
    let writer = try DocWritePolicyTests.service(home, store)
    _ = try await writer.edit(DocWritePolicyTests.request(), input: { old })
    _ = try DocProposalService(environment: writer.environment, workspace: "acme").propose(
      DocProposalRequest(slug: "rules", title: title, why: "Review."), input: { new })
    return store
  }
}
