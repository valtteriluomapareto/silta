import Darwin
import Foundation
import SwiftUI
import SiltaAppSupport

@main
struct SiltaApp: App {
  @State private var model: AppModel

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
    _model = State(initialValue: Self.makeModel())
  }

  private static func makeModel() -> AppModel {
    let arguments = ProcessInfo.processInfo.arguments
    #if DEBUG
      do {
        if try FixtureLaunch.parse(arguments) {
          let fixture = try FixtureLaunch.prepare()
          return makeReaderModel(home: fixture.home, user: fixture.user, now: { fixture.now })
        }
      } catch {
        FileHandle.standardError.write(Data("Silta fixture launch refused: \(error)\n".utf8))
        exit(64)
      }
    #else
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
      home: URL(filePath: path), user: environment["USER"] ?? NSUserName(), now: { Date() })
  }

  private static func makeReaderModel(
    home: URL, user: String, now: @escaping @Sendable () -> Date
  ) -> AppModel {
    do {
      let reader = try AppReader(home: home, user: user, now: now)
      let session = AppReadSession(reader: reader, now: now)
      return AppModel(
        reader: reader,
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
    Window("Silta", id: "main") {
      AppShellView(model: model)
    }.defaultSize(width: 1280, height: 840)
      .commands {
        CommandGroup(after: .sidebar) {
          Button("My work") { model.navigate(to: .mywork) }.keyboardShortcut("1")
          Button("Board") { model.navigate(to: .board) }.keyboardShortcut("2")
          Button("Workspace") { model.navigate(to: .workspace) }.keyboardShortcut("3")
          Button("Toggle Inspector") { model.toggleInspector() }
            .keyboardShortcut("i", modifiers: [.command, .option])
          Divider()
          Button("Refresh") { model.refresh(force: true) }.keyboardShortcut("r")
        }
      }
  }
}
