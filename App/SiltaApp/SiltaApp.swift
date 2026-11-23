import AppKit
import Darwin
import Foundation
import SiltaAppSupport
import SwiftUI

@main
struct SiltaApp: App {
  @State private var model: AppModel
  @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
  #if DEBUG
    private let control: ControlRuntime?
  #endif

  init() {
    #if DEBUG
      do {
        try TestLaunchPolicy.validate(
          environment: ProcessInfo.processInfo.environment,
          temporaryRoots: [FileManager.default.temporaryDirectory, URL(filePath: "/private/tmp")])
      } catch {
        FileHandle.standardError.write(
          Data("Silta test launch refused: invalid isolated home.\n".utf8))
        exit(64)
      }
    #endif
    #if DEBUG
      do {
        if let options = try ControlLaunch.parse(ProcessInfo.processInfo.arguments) {
          let control = try ControlRuntime(options: options)
          self.control = control
          if options.isAutomated {
            Self.pinPreferencesForControl()
          } else if !options.dark {
            Self.apply(Self.storedAppearance)
          }
          let fixture = control.fixture
          // Automated runs start from default Board filters and never store them.
          let model = Self.makeReaderModel(
            home: fixture.home, user: fixture.user, now: { fixture.now },
            defaults: AppModel.filterDefaults(automated: options.isAutomated),
            stateDefaults: AppModel.stateDefaults(fixture: true))
          _model = State(initialValue: model)
          Task { await control.start(model: model) }
          return
        }
        control = nil
      } catch {
        FileHandle.standardError.write(Data("Silta fixture launch refused: \(error)\n".utf8))
        exit(64)
      }
    #endif
    _model = State(initialValue: Self.makeModel())
    Self.apply(Self.storedAppearance)
  }

  private static var storedAppearance: AppAppearance {
    AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.storageKey) ?? "")
      ?? .system
  }

  private static func makeModel() -> AppModel {
    #if !DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains(where: { $0.hasPrefix("-Silta") }) {
        FileHandle.standardError.write(Data("Silta development arguments require Debug.\n".utf8))
        exit(64)
      }
    #endif
    let environment = ProcessInfo.processInfo.environment
    let path =
      environment["SILTA_HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".silta").path
    guard path.hasPrefix("/") else {
      return AppModel(load: { _, _, _ in
        throw AppLoadFailure(
          message: "SILTA_HOME must be an absolute path.", commands: ["unset SILTA_HOME"])
      })
    }
    return makeReaderModel(
      home: URL(filePath: path), user: environment["USER"] ?? NSUserName(), now: { Date() },
      defaults: AppModel.filterDefaults(automated: false),
      stateDefaults: AppModel.stateDefaults(fixture: false))
  }

  private static func makeReaderModel(
    home: URL, user: String, now: @escaping @Sendable () -> Date, defaults: UserDefaults?,
    stateDefaults: UserDefaults?
  ) -> AppModel {
    do {
      let reader = try AppReader(home: home, user: user, now: now)
      let session = AppReadSession(reader: reader, now: now)
      let writer = AppWriter(reader: reader)
      return AppModel(
        reader: reader, now: now,
        writer: { write, workspace in
          try await Task.detached { try await writer.send(write, workspace: workspace) }.value
        },
        defaults: defaults, stateDefaults: stateDefaults,
        load: { previous, workspace, force in
          try await Task.detached {
            try session.load(previous: previous, workspace: workspace, force: force)
          }.value
        })
    } catch {
      let failure = AppLoadFailure(error)
      return AppModel(load: { _, _, _ in throw failure })
    }
  }

  var body: some Scene {
    #if DEBUG
      mainWindow.defaultLaunchBehavior(control?.options.snapshot == nil ? .presented : .suppressed)
    #else
      mainWindow
    #endif
    Settings {
      Form {
        Picker("Appearance", selection: $appearance) {
          ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.radioGroup)
      }.padding(20).frame(width: 320)
        .onChange(of: appearance) { applyAppearance() }
    }
  }

  #if DEBUG
    /// An automated control run shares the installed app's defaults, so it pins the
    /// inspector width in the volatile argument domain: captures stay deterministic and
    /// never read the human's stored width.
    private static func pinPreferencesForControl() {
      let defaults = UserDefaults.standard
      var pinned = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      pinned[SeaInspectorMetrics.storageKey] = SeaInspectorMetrics.width
      defaults.setVolatileDomain(pinned, forName: UserDefaults.argumentDomain)
    }
  #endif

  /// Applies the stored appearance app-wide. An automated Debug control run keeps the
  /// appearance its launch flags chose, so captures stay deterministic.
  private func applyAppearance() {
    #if DEBUG
      if control?.options.isAutomated == true { return }
    #endif
    Self.apply(appearance)
  }

  private static func apply(_ appearance: AppAppearance) {
    NSApplication.shared.appearance = appearance.appearanceName.flatMap(NSAppearance.init(named:))
  }

  private var mainWindow: some Scene {
    Window("Silta", id: "main") {
      AppShellView(model: model)
        .onChange(of: appearance) { applyAppearance() }
        #if DEBUG
          .background {
            if let control { ControlWindowProbe(report: control.attach) }
          }
        #endif
    }.defaultSize(width: 1280, height: 840)
      .commands {
        FindCommands()
        CommandGroup(replacing: .newItem) {
          Button("New Task…") { model.newTaskPresented = true }.keyboardShortcut("n")
            .disabled(model.writer == nil || model.workspace == nil)
        }
        CommandGroup(after: .sidebar) {
          Button("My work") { model.navigate(to: .mywork) }.keyboardShortcut("1")
          Button("Board") { model.navigate(to: .board) }.keyboardShortcut("2")
          Button("Workspace") { model.navigate(to: .workspace) }.keyboardShortcut("3")
          Button("Docs") { model.navigate(to: .docs) }.keyboardShortcut("4")
          Button("Toggle Inspector") { model.toggleInspector() }
            .keyboardShortcut("i", modifiers: [.command, .option])
          Toggle("Show Blocked Tasks", isOn: $model.boardFilter.blocked)
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model.route != .board)
          Divider()
          Button("Refresh") { model.refresh(force: true) }.keyboardShortcut("r")
          Divider()
          Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
          }
        }
      }
  }
}
