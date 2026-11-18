#if DEBUG
  import AppKit
  import Darwin
  import Foundation
  import Observation
  import SwiftUI

  @MainActor final class ControlRuntime {
    let options: ControlLaunch.Options
    let fixture: FixtureLaunch.Configuration
    private let run = UUID().uuidString
    private var revision = 0
    private var model: AppModel?
    private var stateURL: URL {
      (options.snapshot?.deletingLastPathComponent() ?? fixture.home.deletingLastPathComponent())
        .appending(path: "state.json")
    }

    init(options: ControlLaunch.Options) throws {
      self.options = options
      fixture = try FixtureLaunch.prepare()
    }

    func start(model: AppModel) async {
      self.model = model
      do {
        try FileManager.default.createDirectory(
          at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSApplication.shared.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        try observe()
        await model.refresh().value
        try options.route.apply(to: model)
        if model.boardSelection != nil { await model.loadTaskDetail() }
        if model.route == .docs { await model.loadDocuments() }
        if model.route == .workspace { await model.loadWorkspaceDocuments() }
        if let output = options.snapshot {
          try await snapshot(model: model, to: output)
          try publish()
          FileHandle.standardOutput.write(Data((output.path + "\n" + stateURL.path + "\n").utf8))
          exit(0)
        }
        try publish()
        FileHandle.standardOutput.write(Data(("Silta fixture state: " + stateURL.path + "\n").utf8))
      } catch {
        Self.fail(error)
      }
    }

    private func observe() throws {
      guard let model else { return }
      let state = withObservationTracking {
        ControlState(model: model, run: run, revision: revision + 1, dark: options.dark)
      } onChange: { [weak self] in
        Task { @MainActor in
          do { try self?.observe() } catch { Self.fail(error) }
        }
      }
      revision += 1
      try state.write(to: stateURL)
    }

    private func publish() throws {
      guard let model else { return }
      revision += 1
      try ControlState(model: model, run: run, revision: revision, dark: options.dark)
        .write(to: stateURL)
    }

    private func snapshot(model: AppModel, to output: URL) async throws {
      let size = NSSize(width: options.width, height: options.height)
      try await capture(AppShellView(model: model), size: size, to: output)
      let directory = output.deletingLastPathComponent()
      let inspector = directory.appending(path: "inspector.png")
      if FileManager.default.fileExists(atPath: inspector.path) {
        try FileManager.default.removeItem(at: inspector)
      }
      try await capture(
        AppSidebar(model: model), size: NSSize(width: 240, height: size.height),
        to: directory.appending(path: "sidebar.png"))
      if model.route == .board, model.boardInspectorPresented {
        try await capture(
          TaskInspector(model: model), size: NSSize(width: 360, height: size.height),
          to: directory.appending(path: "inspector.png"))
      } else if model.route == .workspace, model.workspaceInspectorPresented,
        let map = model.visibleData?.map
      {
        let connection = WorkspaceContent(map: map, search: model.search)
          .connection(model.workspaceSelection?.connectionRef)
        try await capture(
          ConnectionInspector(connection: connection, model: model),
          size: NSSize(width: 360, height: size.height),
          to: directory.appending(path: "inspector.png"))
      }
    }

    private func capture<Content: View>(_ content: Content, size: NSSize, to output: URL)
      async throws
    {
      let root =
        content
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, .gmt)
        .environment(\.scenePhase, .inactive)
        .environment(\.appearsActive, true)
        .preferredColorScheme(options.dark ? .dark : .light)
        .frame(width: size.width, height: size.height)
        .background(Color("Canvas"))
      let hosting = NSHostingView(rootView: root)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
      window.contentView = hosting
      hosting.frame = NSRect(origin: .zero, size: size)
      hosting.layoutSubtreeIfNeeded()
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      hosting.layoutSubtreeIfNeeded()
      window.display()
      hosting.displayIfNeeded()
      guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw AppLoadFailure(message: "The offscreen root view could not allocate a bitmap.")
      }
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw AppLoadFailure(message: "The offscreen bitmap could not encode PNG.")
      }
      try png.write(to: output, options: .atomic)
      window.close()
    }

    private static func fail(_ error: any Error) -> Never {
      FileHandle.standardError.write(Data("Silta control failed: \(error)\n".utf8))
      exit(74)
    }
  }
#endif
