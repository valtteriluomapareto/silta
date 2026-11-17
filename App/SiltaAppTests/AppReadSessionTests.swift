#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor @Suite(.timeLimit(.minutes(1)))
  struct AppReadSessionTests {
    @Test func persistentReadReloadsOnlyChangedOrExpiredData() throws {
      do {
        try fixture { reader, home in
          let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
          let observer = try reader.makeChangeProbe()
          let before = try observer.version()
          let first = try #require(try session.load(previous: nil, workspace: nil, force: false))
          #expect(first.workspace == "acme")
          #expect(first.snapshot?.work.waitingCount == 5)
          #expect(
            first.snapshot?.board.appOpenCounts == [
              "acme-mobile": 3, "acme-backend": 3, "acme-web": 1,
            ])
          #expect(first.snapshot?.work.items.first?.commands.first?.contains("--approved") == false)
          #expect(try session.load(previous: first, workspace: "acme", force: false) == nil)
          #expect(try observer.version() == before)
          try AppTestCLI.run(
            ["--ws", "acme", "comment", "AC-12", "-m", "Acme refresh"], home: home)
          let changed = try #require(
            try session.load(previous: first, workspace: "acme", force: false))
          #expect(changed.version != first.version)
          let expired = AppLoadedData(
            workspaces: changed.workspaces, workspace: changed.workspace,
            snapshot: changed.snapshot, map: changed.map, version: changed.version,
            checkedAt: AppV2Fixture.now.addingTimeInterval(-60))
          #expect(try session.load(previous: expired, workspace: "acme", force: false) != nil)
        }
      }
    }

    @Test func failedHydrationDoesNotConsumeAChangedVersion() throws {
      do {
        try fixture { reader, home in
          let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
          let first = try #require(try session.load(previous: nil, workspace: "acme", force: false))
          let observer = try reader.makeChangeProbe()
          let before = try observer.version()
          try AppTestCLI.run(["--ws", "acme", "comment", "AC-12", "-m", "Acme retry"], home: home)
          let changed = try observer.version()
          #expect(changed != before)
          let path = home.appending(path: "silta.db").path
          let files = FileManager.default
          let mode = try files.attributesOfItem(atPath: path)[.posixPermissions]
          defer {
            try? files.setAttributes(  // restore permissions after a failed assertion
              [.posixPermissions: mode ?? 0o600], ofItemAtPath: path)
          }
          try files.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
          #expect(try observer.version() == changed)
          #expect(throws: AppReadError.self) {
            try session.load(previous: first, workspace: "acme", force: false)
          }
          try files.setAttributes([.posixPermissions: mode ?? 0o600], ofItemAtPath: path)
          #expect(try observer.version() == changed)
          let retry = try #require(
            try session.load(previous: first, workspace: "acme", force: false))
          #expect(retry.version != first.version)
        }
      }
    }

    @Test func searchHidesEmptyProposalGroupsAndFindsCommentReferences() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      let model = AppModel(
        reader: reader,
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      #expect(model.proposals.count == 3)
      model.search = "unrelated search"
      #expect(model.proposals.isEmpty)
      model.search = "AC-22"
      #expect(model.proposals.count == 1 && model.proposals.first?.refs == ["AC-22"])
      model.search = "agent:codex"
      #expect(model.proposals.count == 2)
      let question = try #require(model.data?.snapshot?.work.items.first { $0.kind == "question" })
      model.search = try #require(question.ref)
      #expect(model.matches(question))
    }

    @Test func missingAndEmptyStoresHaveDifferentOutcomes() throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let reader = try AppReader(home: root.appending(path: "data"), user: "acme")
      let session = AppReadSession(reader: reader)
      do {
        #expect(throws: AppReadError.self) {
          try session.load(previous: nil, workspace: nil, force: false)
        }
      }
      try AppTestCLI.run(["init"], home: root.appending(path: "data"))
      do {
        let empty = try #require(try session.load(previous: nil, workspace: nil, force: false))
        #expect(empty.workspaces.isEmpty && empty.workspace == nil && empty.snapshot == nil)
      }
    }

    private func fixture(_ body: (AppReader, URL) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }), home)
    }
  }
#endif
