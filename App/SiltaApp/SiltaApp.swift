import Darwin
import Foundation
import SwiftUI

@main
struct SiltaApp: App {
  init() {
    #if DEBUG
      do {
        try TestLaunchPolicy.validate(environment: ProcessInfo.processInfo.environment,
          temporaryRoots: [FileManager.default.temporaryDirectory, URL(filePath: "/private/tmp")],
          forbiddenHome: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".silta"))
      } catch {
        FileHandle.standardError.write(Data("Silta test launch refused: invalid isolated home.\n".utf8))
        exit(64)
      }
    #endif
  }

  var body: some Scene {
    Window("Silta", id: "main") {
      Text("Silta").font(.largeTitle).frame(minWidth: 900, minHeight: 600)
    }.defaultSize(width: 1280, height: 840)
  }
}
