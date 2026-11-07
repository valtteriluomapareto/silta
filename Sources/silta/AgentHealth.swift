import Foundation
import SiltaCore

/// Harness-specific inspection stays beside the installer; no harness is executed.
enum AgentHealth {
  static let acceptance =
    "Read docs/dogfood/agents-acceptance.md in a Silta checkout "
    + "and rerun the affected live checks in isolated homes."

  static func inspect(home: URL, at now: Date, environment: [String: String]) -> [DoctorCheck] {
    let user = environment["HOME"] ?? "."
    let claude =
      environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? user + "/.claude"
    let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? user + "/.codex"
    var checks: [DoctorCheck] = []
    let executable = executable("silta", environment)
    checks.append(
      DoctorCheck(
        id: "install.path", status: executable == nil ? .warning : .pass,
        message: executable == nil
          ? "silta is not executable on PATH; installed hooks cannot find it."
          : "silta is executable on PATH; hook-shell PATH may differ.",
        next: executable == nil ? ["command -v silta", "silta agents install --help"] : []))
    checks += ownedPieces(home: home, user: user, claude: claude, codex: codex)
    checks += [
      hook(root: claude, event: "SessionStart", id: "install.hook", user: user),
      hook(root: claude, event: "Stop", id: "install.claude.stop", user: user),
    ]
    checks += AgentHealthLogs.inspect(home: home, at: now)
    checks += versions(environment)
    let order = [
      "install.path", "install.hook", "install.skill", "install.codex_root",
      "install.codex.instructions", "install.claude.instructions", "install.claude.stop",
      "install.opencode.skill", "install.claude.session_start", "install.claude.last_stop",
      "install.claude.session", "install.claude.version", "install.codex.version",
      "install.codex.hooks", "install.opencode.version", "install.opencode.hooks",
    ]
    return order.compactMap { id in checks.first { $0.id == id } }
  }

  private static func ownedPieces(home: URL, user: String, claude: String, codex: String)
    -> [DoctorCheck]
  {
    var checks: [DoctorCheck] = []
    do {
      let targets = try AgentInstallTarget.selected(claude: true, codex: true, root: home.path)
      for (index, target) in targets.enumerated() {
        let ids = [
          "install.skill", "install.claude.instructions", "install.codex.instructions",
          "install.codex_root",
        ]
        let root = index < 2 ? claude : codex
        let path = target.path.split(separator: "/").dropFirst().joined(separator: "/")
        checks.append(piece(id: ids[index], root: root, path: path, target: target, user: user))
        if index == 0 {
          checks.append(
            piece(
              id: "install.opencode.skill", root: user + "/.claude", path: path, target: target,
              user: user)
          )
        }
      }
    } catch {
      checks.append(
        DoctorCheck(
          id: "install.skill", status: .warning,
          message: "Could not construct installed-content expectations.",
          next: ["silta agents install --help"]))
    }
    return checks
  }

  private static func versions(_ environment: [String: String]) -> [DoctorCheck] {
    var checks: [DoctorCheck] = []
    for (name, baseline) in [("claude", "2.1.314"), ("codex", "0.166.0"), ("opencode", nil)] {
      checks.append(version(name, baseline: baseline, environment: environment))
      if name != "claude" {
        checks.append(
          DoctorCheck(
            id: "install.\(name).hooks", status: .skipped,
            message: "\(name): no Silta hook integration; no hook-session evidence is available."))
      }
    }
    return checks
  }

  private static func piece(
    id: String, root: String, path: String, target: AgentInstallTarget, user: String
  )
    -> DoctorCheck
  {
    let codex = target.path.hasPrefix(".codex")
    let overridden = root != user + (codex ? "/.codex" : "/.claude")
    let inspection = "/bin/ls -ld " + shellWord(root) + " " + shellWord(root + "/" + path)
    let next =
      overridden
      ? [inspection, "silta agents install --help"]
      : [
        "silta agents install" + (codex ? " --codex" : " --claude") + " --dry-run"
      ]
    do {
      guard let old = try AgentHealthFiles.read(root: root, path: path) else {
        return DoctorCheck(
          id: id, status: .warning,
          message: "owned piece is absent in the effective configuration directory.",
          next: next, nextBy: overridden ? .human : .agent)
      }
      let expected = try target.replace(old, existed: true, uninstall: false) {
        throw TaskError.input
      }
      let intact = old == expected
      return DoctorCheck(
        id: id, status: intact ? .pass : .warning,
        message: intact
          ? "owned piece is intact and current."
          : "owned piece is missing or stale; preview the expected content.",
        next: intact ? [] : next, nextBy: overridden ? .human : .agent)
    } catch {
      return DoctorCheck(
        id: id, status: .fail,
        message:
          "cannot safely read or validate ownership; "
          + "inspect the effective configuration directory.",
        next: [inspection, "silta agents install --help"], nextBy: .human)
    }
  }

  private static func hook(root: String, event: String, id: String, user: String) -> DoctorCheck {
    let overridden = root != user + "/.claude"
    let inspection = "/bin/ls -ld " + shellWord(root) + " " + shellWord(root + "/settings.json")
    let next =
      overridden
      ? [inspection, "silta agents install --help"]
      : [
        "silta agents install --claude " + (event == "Stop" ? "--stop-hook" : "--hook")
          + " --dry-run"
      ]
    do {
      let old = try AgentHealthFiles.read(root: root, path: "settings.json")
      let intact = try old.flatMap { try AgentHookSettings.intact($0, event: event) }
      return DoctorCheck(
        id: id, status: intact == true ? .pass : intact == nil ? .skipped : .warning,
        message: intact == true
          ? "Claude \(event): owned hook is intact."
          : intact == nil
            ? "Claude \(event): optional owned hook is absent."
            : "Claude \(event): owned hook is stale.", next: intact == true ? [] : next,
        nextBy: overridden ? .human : .agent)
    } catch {
      return DoctorCheck(
        id: id, status: .fail,
        message: "Claude \(event): settings or owned hook cannot be safely validated.",
        next: [inspection, "silta agents install --help"], nextBy: .human)
    }
  }

  static func executable(_ name: String, _ environment: [String: String]) -> URL? {
    for directory in (environment["PATH"] ?? "").split(
      separator: ":", omittingEmptySubsequences: false)
    {
      let root =
        directory.hasPrefix("/")
        ? URL(filePath: String(directory))
        : URL(filePath: FileManager.default.currentDirectoryPath).appending(path: String(directory))
      let file = root.appending(path: name)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        FileManager.default.isExecutableFile(atPath: file.path)
      {
        return file.resolvingSymlinksInPath()
      }
    }
    return nil
  }

  private static func version(_ name: String, baseline: String?, environment: [String: String])
    -> DoctorCheck
  {
    let path = executable(name, environment)?.path ?? ""
    let components = path.split(separator: "/").map(String.init)
    let anchor =
      name == "claude" ? ["claude", "versions"] : [name == "codex" ? "Caskroom" : "Cellar", name]
    var version: String?
    for index in components.indices where index + 2 < components.count {
      if Array(components[index..<(index + 2)]) == anchor {
        let candidate = components[index + 2]
        let tail = Array(components.dropFirst(index + 3))
        if candidate.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil,
          tail == (name == "claude" ? [] : ["bin", name])
        {
          version = candidate
        }
      }
    }
    let matches = version != nil && version == baseline
    let message: String
    if let version {
      message =
        "\(name): installed metadata version \(version); "
        + (baseline.map { "last live-verified \($0) on 2026-11-06." }
          ?? "no live-verified baseline.")
    } else {
      message =
        "\(name): installed metadata version unknown (missing executable or unsupported installation layout); "
        + (baseline.map { "last live-verified \($0) on 2026-11-06." }
          ?? "no live-verified baseline.")
    }
    return DoctorCheck(
      id: "install.\(name).version", status: matches ? .pass : .warning,
      message: message, next: matches ? [] : version == nil ? ["\(name) --version"] : [acceptance],
      nextBy: .human)
  }
}
