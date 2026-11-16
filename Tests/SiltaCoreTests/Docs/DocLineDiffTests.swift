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
      withKnownIssue("Metadata changes expand an otherwise small body edit") {
        #expect(output.components(separatedBy: "\n").count < 60)
        #expect(output.contains(append ? "@@ -1498,3 +1498,4 @@" : "@@ -747,7 +747,7 @@"))
        #expect(!output.contains("-# Acme rules") && !output.contains("+# Acme rules"))
      }
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
      withKnownIssue("A replacement span includes all lines between distant edits") {
        #expect(output.components(separatedBy: "\n").count < 80)
        #expect(
          output.components(separatedBy: "\n").filter { $0.hasPrefix("@@ ") }.count
            == (distant ? 2 : 1))
      }
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
      withKnownIssue("Metadata occupies body diff coordinates") {
        #expect(output.contains(change.hunk))
      }
    }
  }

  @Test func metadataOnlyChangeHasNoBodyHunk() async throws {
    try await withScratchDirectory { home in
      let store = try await fixture(home, old: "Same body", new: "Same body")
      let output = try DocService(workspace: "acme", store: store).show("doc:rules@2", diff: true)
        .output
      #expect(
        output.contains("Review.") && !output.contains("-Same body")
          && !output.contains("+Same body"))
      withKnownIssue("Metadata-only changes are rendered as a body patch") {
        #expect(!output.contains("@@ "))
      }
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
        DocProposalRequest(slug: "rules", why: "Review."), input: { "Same body" })
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
        withKnownIssue("Identity-only changes are omitted from revision diffs") {
          #expect(output.contains("attachment identities: changed"))
          #expect(!output.contains("no visible changes"))
        }
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

  private func fixture(_ home: URL, old: String, new: String) async throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: home)
    let writer = try DocWritePolicyTests.service(home, store)
    _ = try await writer.edit(DocWritePolicyTests.request(), input: { old })
    _ = try DocProposalService(environment: writer.environment, workspace: "acme").propose(
      DocProposalRequest(slug: "rules", why: "Review."), input: { new })
    return store
  }
}
