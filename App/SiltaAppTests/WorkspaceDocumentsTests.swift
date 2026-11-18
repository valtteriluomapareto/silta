#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct WorkspaceDocumentsTests {
    @Test func documentsGroupRevisionsAndQualifyPartialPages() async throws {
      try await fixture { reader in
        let edge = "edge:acme-mobile/acme-backend/http-api"
        let page = try reader.documents(workspace: "acme", about: edge)
        let flags = WorkspaceReadFlags()
        let docs = WorkspaceDocumentsModel(read: { _, _, refs in
          flags.calls += 1
          let value =
            flags.partial
            ? AppDocumentList(
              entries: Array(page.entries.prefix(1)), total: page.total, nextOffset: 1) : page
          return Dictionary(uniqueKeysWithValues: refs.map { ($0, value) })
        })
        await docs.refresh(reader, workspace: "acme", version: 1, connections: [edge])
        #expect(docs.groups(for: edge).count == 3 && docs.countLabel(for: edge) == "3 docs")
        #expect(docs.groups(for: edge).first { $0.id == "order-contract" }?.entries.count == 2)
        await docs.refresh(reader, workspace: "acme", version: 1, connections: [edge])
        #expect(flags.calls == 1)
        flags.partial = true
        await docs.refresh(reader, workspace: "acme", version: 1, connections: [edge], force: true)
        #expect(
          flags.calls == 2 && docs.countText(for: edge) == "1+"
            && docs.countLabel(for: edge) == "1+ docs"
        )
      }
    }

    @Test(arguments: [1, 2]) func reloadFailureRetainsValuesAndRetryClearsTheFailure(version: Int)
      async throws
    {
      try await fixture { reader in
        let edge = "edge:acme-mobile/acme-backend/http-api"
        let page = try reader.documents(workspace: "acme", about: edge)
        let flags = WorkspaceReadFlags()
        let gate = PausedWorkspaceRead()
        let retryGate = PausedWorkspaceRead()
        let docs = WorkspaceDocumentsModel(read: { _, _, _ in
          if flags.fails {
            await gate.pause()
            throw AppLoadFailure(message: "Acme read failed")
          }
          if flags.pauses { await retryGate.pause() }
          return [edge: page]
        })
        await docs.refresh(reader, workspace: "acme", version: 1, connections: [edge])
        flags.fails = true
        let reload = Task {
          await docs.refresh(
            reader, workspace: "acme", version: version, connections: [edge], force: true)
        }
        await gate.started()
        #expect(docs.loading && docs.countLabel(for: edge) == "3 docs")
        gate.resume()
        await reload.value
        #expect(docs.failure != nil && docs.countLabel(for: edge) == "3 docs (stale)")
        #expect(docs.countText(for: edge) == "3 (stale)")
        #expect(docs.phase(workspace: "acme", version: version, connections: [edge]) == .failed)
        flags.fails = false
        flags.pauses = true
        let retry = Task {
          await docs.refresh(
            reader, workspace: "acme", version: version, connections: [edge], force: true)
        }
        await retryGate.started()
        #expect(docs.loading)
        withKnownIssue("A forced retry must retain stale qualifiers until it succeeds") {
          #expect(docs.countLabel(for: edge) == "3 docs (stale)")
          #expect(docs.countText(for: edge) == "3 (stale)")
        }
        retryGate.resume()
        await retry.value
        #expect(docs.failure == nil && !docs.loading)
        #expect(docs.countLabel(for: edge) == "3 docs" && docs.countText(for: edge) == "3")
        #expect(docs.phase(workspace: "acme", version: version, connections: [edge]) == .ready)
      }
    }

    @Test func cancelledConnectionReadStopsBeforeTheNextConnection() async throws {
      let operation = Task.detached {
        var calls: [String] = []
        do {
          _ = try WorkspaceDocumentsModel.readPages(connections: ["first", "second"]) { ref in
            calls.append(ref)
            withUnsafeCurrentTask { $0?.cancel() }
            return AppDocumentList(entries: [], total: 0, nextOffset: nil)
          }
        } catch { #expect(error is CancellationError) }
        return calls
      }
      let calls = await operation.value
      #expect(calls == ["first"])
    }

    @Test(arguments: [false, true]) func overlappingReadersJoinTheSameFlight(force: Bool)
      async throws
    {
      try await fixture { reader in
        let gate = PausedWorkspaceRead()
        let flags = WorkspaceReadFlags()
        let docs = WorkspaceDocumentsModel(read: { _, _, _ in
          flags.calls += 1
          if !force || flags.calls > 1 { await gate.pause() }
          return [:]
        })
        if force { await docs.refresh(reader, workspace: "acme", version: 1, connections: []) }
        let first = Task {
          await docs.refresh(reader, workspace: "acme", version: 1, connections: [], force: force)
        }
        await gate.started()
        let release = Task { gate.resume() }
        await docs.refresh(reader, workspace: "acme", version: 1, connections: [])
        #expect(flags.calls == (force ? 2 : 1))
        #expect(!docs.loading)
        await first.value
        await release.value
      }
    }

    @Test(arguments: [false, true]) func oldWorkspaceCompletionCannotReplaceTheNewScope(fails: Bool)
      async throws
    {
      try await fixture { reader in
        let gate = PausedWorkspaceRead()
        let docs = WorkspaceDocumentsModel(read: { _, workspace, _ in
          if workspace == "acme" {
            await gate.pause()
            if fails { throw AppLoadFailure(message: "Old Acme read failed") }
            return ["old": AppDocumentList(entries: [], total: 0, nextOffset: nil)]
          }
          return [:]
        })
        let old = Task {
          await docs.refresh(reader, workspace: "acme", version: 1, connections: [])
        }
        await gate.started()
        await docs.refresh(reader, workspace: "beta", version: 1, connections: [])
        gate.resume()
        await old.value
        #expect(docs.pages.isEmpty && docs.failure == nil)
        #expect(docs.phase(workspace: "beta", version: 1, connections: []) == .ready)
      }
    }

    @Test func workspaceSnapshotWaitsForDocsAndDocumentNavigationKeepsItsConnection() async throws {
      try await fixture { reader in
        let map = try reader.workspaceMap(workspace: "acme")
        let snapshot = try reader.snapshot(workspace: "acme")
        let model = AppModel(
          reader: reader,
          load: { _, _, _ in
            AppLoadedData(
              workspaces: [], workspace: "acme", snapshot: snapshot, map: map,
              version: 1, checkedAt: AppV2Fixture.now)
          })
        await model.refresh().value
        let edge = "edge:acme-mobile/acme-backend/http-api"
        model.select(connection: edge)
        let loading = ControlState(model: model, run: "test", revision: 1, dark: false)
        #expect(!loading.idle && loading.refresh.phase == "loading")
        await model.loadWorkspaceDocuments()
        let ready = ControlState(model: model, run: "test", revision: 2, dark: false)
        #expect(ready.idle && ready.refresh.phase == "ready")
        #expect(ready.selection?.ref == edge && ready.counts.sidebar?.waiting == 7)
        #expect(model.workspaceDocuments.countLabel(for: edge) == "3 docs")
        model.openDocument("doc:order-contract@2", view: .document)
        #expect(model.route == .docs && model.documents.view == .document)
        #expect(
          model.workspaceSelection?.connectionRef == edge && model.workspaceInspectorPresented)
      }
    }

    private func fixture(_ body: @MainActor (AppReader) async throws -> Void) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      try await body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }
  }

  @MainActor private final class WorkspaceReadFlags {
    var partial = false
    var fails = false
    var pauses = false
    var calls = 0
  }

  @MainActor private final class PausedWorkspaceRead {
    private var hasStarted = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var starter: CheckedContinuation<Void, Never>?
    func pause() async {
      hasStarted = true
      starter?.resume()
      starter = nil
      await withCheckedContinuation { waiter = $0 }
    }
    func started() async {
      if hasStarted { return }
      await withCheckedContinuation { starter = $0 }
    }
    func resume() {
      waiter?.resume()
      waiter = nil
    }
  }
#endif
