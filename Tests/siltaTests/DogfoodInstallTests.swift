import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(3)))
struct DogfoodInstallTests {
  static let appName = "Silta Dev.app"

  static func git(_ args: [String], in scratch: URL, cwd: URL) throws -> String {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args,
      in: scratch, cwd: cwd)
    #expect(result.termination == .exit(0))
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func clone(_ scratch: URL) throws -> URL {
    let origin = scratch.appending(path: "origin")
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    _ = try git(["init", "-q", "-b", "main"], in: scratch, cwd: origin)
    let scripts = origin.appending(path: "scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: DogfoodReportTests.root.appending(path: "scripts/install-dev.sh"),
      to: scripts.appending(path: "install-dev.sh"))
    try Data(".build/\n".utf8).write(to: origin.appending(path: ".gitignore"))
    _ = try git(["add", "."], in: scratch, cwd: origin)
    _ = try git(
      [
        "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm",
        "Acme installer",
      ], in: scratch, cwd: origin)
    let clone = scratch.appending(path: "clone")
    _ = try git(["clone", "-q", origin.path, clone.path], in: scratch, cwd: scratch)
    return clone
  }

  /// A `swift` stub that writes `text` as the release binary.
  static func swift(_ text: String, in tools: URL) throws {
    try DogfoodReportTests.tool(
      "swift",
      text: """
        #!/bin/bash
        [[ "$*" == 'build -c release --only-use-versions-from-resolved-file' ]] || exit 98
        mkdir -p .build/release
        printf '%s' \(shellWord(text)) > .build/release/silta
        """, in: tools)
  }

  /// An `xcodebuild` stub that writes a Release app recording its arguments and `text`, with
  /// `CFBundleVersion` taken from `CURRENT_PROJECT_VERSION` like the real build.
  static func xcodebuild(_ text: String, in tools: URL) throws {
    try DogfoodReportTests.tool(
      "xcodebuild",
      text: """
        #!/bin/bash
        app=.build/app/DerivedData/Build/Products/Release/SiltaApp.app/Contents
        rm -rf "$app" && mkdir -p "$app"
        for argument in "$@"; do
          case "$argument" in CURRENT_PROJECT_VERSION=*) version="${argument#*=}" ;; esac
        done
        printf '%s\\n' "$@" > "$app/args"
        printf '%s' \(shellWord(text)) > "$app/marker"
        cat > "$app/Info.plist" <<PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleVersion</key><string>$version</string>
        </dict></plist>
        PLIST
        """, in: tools)
  }

  /// An `mv` stub that fails only when moving the staged app into place.
  static func failingAppSwap(in tools: URL) throws {
    try DogfoodReportTests.tool(
      "mv",
      text: """
        #!/bin/bash
        [[ "$1" == */.silta-app.*/Silta\\ Dev.app ]] && exit 1
        exec /bin/mv "$@"
        """, in: tools)
  }

  static func failing(_ name: String, scratch: URL, in tools: URL, status: Int = 99) throws {
    try DogfoodReportTests.tool(
      name,
      text: "#!/bin/bash\necho \(name) >> "
        + shellWord(scratch.appending(path: "build-called").path) + "\nexit \(status)\n",
      in: tools)
  }

  static func install(_ clone: URL, scratch: URL, tools: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"),
      [clone.appending(path: "scripts/install-dev.sh").path], in: scratch,
      environment: [
        "PATH": tools.path + ":/usr/bin:/bin",
        "SILTA_INSTALL_DIR": scratch.appending(path: "installed").path,
        "SILTA_APP_INSTALL_DIR": scratch.appending(path: "apps").path,
      ])
  }

  static func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  @Test func installerRefusesDirtyOtherBranchAndDetachedBeforeBuild() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try Self.failing("swift", scratch: scratch, in: tools)
      try Self.failing("xcodebuild", scratch: scratch, in: tools)
      try Data("Acme untracked".utf8).write(to: clone.appending(path: "untracked"))
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      try FileManager.default.removeItem(at: clone.appending(path: "untracked"))
      _ = try Self.git(["checkout", "-qb", "codex/acme"], in: scratch, cwd: clone)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      _ = try Self.git(["checkout", "--detach", "-q"], in: scratch, cwd: clone)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "build-called").path))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "installed/silta").path))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "apps").path))
    }
  }

  @Test(arguments: ["behind", "ahead"])
  func installerRefusesMainThatDiffersFromOrigin(direction: String) throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try Self.failing("swift", scratch: scratch, in: tools)
      try Self.failing("xcodebuild", scratch: scratch, in: tools)
      let commit = [
        "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit",
        "--allow-empty", "-qm", "Acme " + direction,
      ]
      let repository = direction == "behind" ? scratch.appending(path: "origin") : clone
      _ = try Self.git(commit, in: scratch, cwd: repository)
      let result = try Self.install(clone, scratch: scratch, tools: tools)
      #expect(result.termination == .exit(1))
      #expect(result.stderr.contains(direction == "behind" ? "1 behind" : "1 ahead"))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "build-called").path))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "installed/silta").path))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "apps").path))
    }
  }

  @Test func installerInstallsCLIAndAppFromOneCommit() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try Self.swift("Acme binary", in: tools)
      try Self.xcodebuild("Acme app", in: tools)
      let result = try Self.install(clone, scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      let app = scratch.appending(path: "apps").appending(path: Self.appName)
        .appending(path: "Contents")
      #expect(try Self.read(scratch.appending(path: "installed/silta")) == "Acme binary")
      #expect(try Self.read(app.appending(path: "marker")) == "Acme app")
      let short = try Self.git(["rev-parse", "--short=12", "HEAD"], in: scratch, cwd: clone)
      let args = try Self.read(app.appending(path: "args")).split(separator: "\n").map(String.init)
      for expected in [
        "-project", "App/SiltaApp.xcodeproj", "-scheme", "SiltaApp", "-configuration", "Release",
        "-onlyUsePackageVersionsFromResolvedFile", "CURRENT_PROJECT_VERSION=" + short, "build",
      ] {
        #expect(args.contains(expected), "missing xcodebuild argument \(expected)")
      }
      let commit = try Self.git(["rev-parse", "HEAD"], in: scratch, cwd: clone)
      #expect(result.stdout.contains(commit))
      #expect(result.stdout.contains(Self.appName))
      #expect(result.stdout.contains("Next: follow "))
      #expect(result.stdout.contains("/docs/getting-started.md.\n"))
      let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "apps").path)
      #expect(leftovers == [Self.appName])
    }
  }

  @Test func installerReplacesAnExistingAppWithoutLeftovers() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try Self.swift("Acme binary", in: tools)
      try Self.xcodebuild("Acme app", in: tools)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination == .exit(0))
      let app = scratch.appending(path: "apps").appending(path: Self.appName)
      try Data("Acme stale".utf8).write(to: app.appending(path: "Contents/old-only"))
      try Self.swift("Acme binary 2", in: tools)
      try Self.xcodebuild("Acme app 2", in: tools)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination == .exit(0))
      #expect(try Self.read(scratch.appending(path: "installed/silta")) == "Acme binary 2")
      #expect(try Self.read(app.appending(path: "Contents/marker")) == "Acme app 2")
      let oldOnly = app.appending(path: "Contents/old-only")
      #expect(!FileManager.default.fileExists(atPath: oldOnly.path))
      let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "apps").path)
      #expect(leftovers == [Self.appName])
    }
  }

  @Test(arguments: [
    "swift", "xcodebuild", "missing-cli", "missing-app", "stale-app", "ditto", "app-swap",
  ])
  func installerKeepsBothInstallsWhenAnyStepFails(failure: String) throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try Self.swift("Acme binary", in: tools)
      try Self.xcodebuild("Acme app", in: tools)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination == .exit(0))
      try Self.swift("Acme binary 2", in: tools)
      try Self.xcodebuild("Acme app 2", in: tools)
      switch failure {
      case "swift", "xcodebuild", "ditto":
        try Self.failing(failure, scratch: scratch, in: tools, status: 42)
      case "missing-cli":
        try FileManager.default.removeItem(at: clone.appending(path: ".build"))
        try DogfoodReportTests.tool("swift", text: "#!/bin/bash\nexit 0\n", in: tools)
      case "missing-app":
        try FileManager.default.removeItem(at: clone.appending(path: ".build"))
        try DogfoodReportTests.tool("xcodebuild", text: "#!/bin/bash\nexit 0\n", in: tools)
      case "stale-app":
        let origin = scratch.appending(path: "origin")
        _ = try Self.git(
          [
            "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit",
            "--allow-empty", "-qm", "Acme next",
          ], in: scratch, cwd: origin)
        _ = try Self.git(["pull", "-q", "--ff-only"], in: scratch, cwd: clone)
        try DogfoodReportTests.tool("xcodebuild", text: "#!/bin/bash\nexit 0\n", in: tools)
      default:
        try Self.failingAppSwap(in: tools)
      }
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(try Self.read(scratch.appending(path: "installed/silta")) == "Acme binary")
      let app = scratch.appending(path: "apps").appending(path: Self.appName)
      #expect(try Self.read(app.appending(path: "Contents/marker")) == "Acme app")
      let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "apps").path)
      #expect(leftovers == [Self.appName])
    }
  }

  @Test func defaultInstallDirectoriesUseOnlyTheTemporaryHome() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try Self.swift("Acme", in: tools)
      try Self.xcodebuild("Acme app", in: tools)
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"),
        [clone.appending(path: "scripts/install-dev.sh").path], in: scratch,
        environment: ["PATH": tools.path + ":/usr/bin:/bin"])
      #expect(result.termination == .exit(0))
      #expect(
        FileManager.default.fileExists(
          atPath: scratch.appending(path: "home/.local/bin/silta").path))
      #expect(
        FileManager.default.fileExists(
          atPath: scratch.appending(path: "home/Applications").appending(path: Self.appName)
            .appending(path: "Contents/marker").path))
    }
  }
}
