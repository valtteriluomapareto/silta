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
          #expect(first.snapshot?.work.waitingCount == 7)
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

    @Test func forceAndWorkspaceChangesReloadAnUnchangedVersion() throws {
      try fixture { reader, _ in
        let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
        let first = try #require(try session.load(previous: nil, workspace: "acme", force: false))
        #expect(try session.load(previous: first, workspace: "acme", force: false) == nil)
        let forced = try #require(try session.load(previous: first, workspace: "acme", force: true))
        #expect(forced.version == first.version && forced.snapshot == first.snapshot)
        let other = AppLoadedData(
          workspaces: [], workspace: "other", snapshot: nil, map: nil,
          version: first.version, checkedAt: first.checkedAt)
        let selected = try #require(
          try session.load(previous: other, workspace: "acme", force: false))
        #expect(selected.workspace == "acme" && selected.version == first.version)
      }
    }

    @Test func aReplacementReloadsWhenItsDataVersionIsEqual() throws {
      try fixture { reader, home in
        let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
        let first = try #require(try session.load(previous: nil, workspace: "acme", force: false))
        let root = home.deletingLastPathComponent()
        let other = root.appending(path: "replacement")
        try AppV2Fixture.seed(home: other)
        let yaml = try AppTestCLI.run(["ws", "show", "acme"], home: other)
        let updated = yaml.replacingOccurrences(
          of: #""name":"Acme""#, with: #""name":"Acme Replacement""#)
        try #require(updated != yaml)
        let edited = root.appending(path: "replacement.yaml")
        try updated.write(to: edited, atomically: true, encoding: .utf8)
        try AppTestCLI.run(
          ["ws", "edit", "acme", "-F", edited.path, "--approved", "Rename the Acme fixture"],
          home: other)
        let entry = home.appending(path: "silta.db")
        try FileManager.default.moveItem(at: entry, to: root.appending(path: "original.db"))
        try FileManager.default.createSymbolicLink(
          at: entry, withDestinationURL: other.appending(path: "silta.db"))
        let reloaded = try #require(
          try session.load(previous: first, workspace: "acme", force: false))
        #expect(reloaded.version == first.version)
        #expect(reloaded.workspace == "acme" && reloaded.snapshot != nil)
        #expect(reloaded.workspaces.first { $0.slug == "acme" }?.name == "Acme Replacement")
        #expect(try session.load(previous: reloaded, workspace: "acme", force: false) == nil)
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
      let data = try #require(model.visibleData)
      let snapshot = try #require(data.snapshot)
      func content() -> MyWorkContent {
        MyWorkContent(snapshot: snapshot, apps: [], search: model.search, now: data.checkedAt)
      }
      #expect(content().tasks.count == 3)
      model.search = "unrelated search"
      #expect(content().tasks.isEmpty && !content().hasMatches)
      model.search = "AC-22"
      #expect(content().tasks.count == 1 && content().tasks.first?.ref == "AC-22")
      model.search = "agent:codex"
      #expect(content().tasks.count == 2)
      let questionItem = snapshot.work.items.first { $0.kind == "question" }
      let question = try #require(questionItem)
      model.search = try #require(question.ref)
      #expect(content().questions.count == 1 && content().questions.first?.item.ref == question.ref)

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
