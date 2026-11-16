import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTargetSnapshotTests {
  @Test(arguments: ["app", "service", "topic", "edge"])
  func directEditsCaptureKnownTargetsAndPreserveHistory(kind: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try DocWritePolicyTests.service(home, store, approved: "Keep Acme rules")
      let ref =
        kind == "edge"
        ? "edge:api/service:push/sdk"
        : kind + ":" + (kind == "app" ? "api" : kind == "service" ? "push" : "messaging")
      _ = try await service.edit(
        DocEditRequest(slug: "rules", title: "Rules", about: [ref]), input: { "Body." })
      let raw = try Self.snapshot(store, revision: 1)
      do {
        #expect(raw != nil)
      }
      if let raw {
        let actual = try JSONDecoder().decode([DocTargetIdentity].self, from: Data(raw.utf8))
        let uid = try #require(
          try store.read { try String.fetchOne($0, sql: "SELECT uid FROM \(kind) LIMIT 1") })
        #expect(actual == [DocTargetIdentity(kind: kind, uid: uid)])
        try store.write {
          try $0.database.execute(
            sql: kind == "edge"
              ? "UPDATE edge SET kind='HTTP API'" : "UPDATE \(kind) SET slug='renamed'")
        }
        _ = try await service.edit(DocEditRequest(slug: "rules"), input: { "Another body." })
        #expect(try Self.snapshot(store, revision: 1) == raw)
        #expect(try Self.snapshot(store, revision: 2) == raw)
      }
    }
  }

  @Test(arguments: ["rebound", "reordered", "unknown"])
  func inboxComparesKnownIdentitySetsWithoutInventingHistory(mode: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try DocWritePolicyTests.service(home, store, approved: "Keep Acme rules")
      _ = try await service.edit(
        DocEditRequest(slug: "rules", title: "Rules", about: ["service:push", "topic:messaging"]),
        input: { "Body." })
      let known = try store.read { db in
        try ["service", "topic"].map {
          DocTargetIdentity(
            kind: $0,
            uid: try #require(try String.fetchOne(db, sql: "SELECT uid FROM \($0) LIMIT 1")))
        }
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let importedBytes = try encoder.encode(known)
      let imported = try #require(String(data: importedBytes, encoding: .utf8))
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET about_targets=?",
          arguments: [mode == "unknown" ? nil : imported])
        if mode == "rebound" {
          try $0.database.execute(sql: "UPDATE service SET uid='replacement-service'")
        }
      }
      _ = try DocProposalService(environment: service.environment, workspace: "acme").propose(
        DocProposalRequest(slug: "rules", why: "Share."), input: { "Body." })
      if mode == "reordered" {
        let reversedBytes = try encoder.encode(Array(known.reversed()))
        let reversed = try #require(String(data: reversedBytes, encoding: .utf8))
        try store.write {
          try $0.database.execute(
            sql: "UPDATE doc_rev SET about_targets=? WHERE rev=2", arguments: [reversed])
        }
      }
      let before = try Self.snapshot(store, revision: 1)
      let member = try #require(try DocProposalInboxTests().preview(store).first?.members.first)
      if mode == "rebound" {
        do {
          #expect(member.summary.contains("about changed"))
        }
      } else {
        #expect(!member.summary.contains("about changed"))
      }
      #expect(try Self.snapshot(store, revision: 1) == before)
      if mode == "unknown" { #expect(before == nil) }
    }
  }

  @Test func acceptedTargetSnapshotsRoundTripInFormatFour() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try DocWritePolicyTests.service(home, store, approved: "Keep Acme rules")
      _ = try await service.edit(
        DocEditRequest(slug: "rules", title: "Rules", about: ["service:push"]),
        input: { "Body." })
      let tree = try ExportTree.parse(ExportTreeTests.render(store))
      let record = try #require(tree.documents.documents.first?.records.first)
      do {
        #expect(record.value("about_targets") != nil)
      }
      if record.value("about_targets") != nil {
        let directory = try RestoreSupport.write(tree.files(), to: home.appending(path: "export"))
        let destination = ExportFixture.store(home.appending(path: "destination"))
        try destination.initialize()
        _ = try RestoreSupport.restore(
          directory, into: destination, home: home.appending(path: "destination"))
        let restored = try ExportTree.parse(ExportTreeTests.render(destination))
        #expect(restored.documents == tree.documents)
      }
    }
  }

  private static func snapshot(_ store: DatabaseStore, revision: Int) throws -> String? {
    try store.read {
      try String.fetchOne(
        $0, sql: "SELECT about_targets FROM doc_rev WHERE rev=?", arguments: [revision])
    }
  }
}
