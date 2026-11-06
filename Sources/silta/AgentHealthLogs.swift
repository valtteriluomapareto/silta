import Darwin
import Foundation
import SiltaCore

/// A complete retained-log scan is required before old successes can imply health.
enum AgentHealthLogs {
  private struct Entry: Decodable {
    let timestamp: String
    let command: String
    let actor: String
    let exitCode: Int
    let milliseconds: Int
    let errorCode: String?
    let warnings: [String]
    let sessionMatchesActor: Bool?

    var healthy: Bool {
      exitCode == 0 && errorCode == nil && warnings.isEmpty && actor.hasPrefix("agent:claude:")
    }
  }

  static func inspect(home: URL, at now: Date) -> [DoctorCheck] {
    var entries: [Entry] = []
    var problem: EvidenceProblem?
    do { entries = try read(home: home, at: now) } catch let failure as EvidenceProblem {
      problem = failure
    } catch {
      problem = EvidenceProblem(
        path: home.appending(path: "log"), reason: "Retained log inventory cannot be inspected.")
    }
    let complete = problem == nil
    let next = problem?.next(home: home) ?? [AgentHealth.acceptance]
    let detail = problem.map { " " + $0.reason + " Evidence: " + $0.path.path + "." } ?? ""
    var checks = [
      ("silta agents session-start", "install.claude.session_start", "SessionStart"),
      ("silta agents stop", "install.claude.last_stop", "Stop"),
    ].map { command, id, label in
      let entry = entries.last { $0.command == command }
      let event =
        entry.map {
          "Last Claude \(label): \($0.timestamp), exit \($0.exitCode), \($0.milliseconds) ms; "
            + ($0.healthy
              ? "no logged error or warning." : "logged failure, warning or unexpected actor.")
        } ?? "Claude \(label): no retained hook record."
      return DoctorCheck(
        id: id, status: complete && entry?.healthy == true ? .pass : .warning,
        message: event
          + (complete ? "" : " Retained log evidence is incomplete or invalid; health is unknown.")
          + detail,
        next: complete && entry?.healthy == true ? [] : next, nextBy: .human)
    }
    checks.append(propagation(entries, complete: complete, detail: detail, next: next))
    return checks
  }

  private static func propagation(
    _ entries: [Entry], complete: Bool, detail: String, next: [String]
  ) -> DoctorCheck {
    let start = entries.lastIndex {
      $0.command == "silta agents session-start"
    }
    let ordinary = start.flatMap { index in
      entries.dropFirst(index + 1).last {
        $0.actor == entries[index].actor && $0.command != "silta agents session-start"
          && $0.command != "silta agents stop"
      }
    }
    let latestHook = entries.last {
      $0.command == "silta agents session-start" || $0.command == "silta agents stop"
    }
    let observed =
      complete && start.map { entries[$0].healthy } == true && ordinary?.sessionMatchesActor == true
      && latestHook?.actor == start.map { entries[$0].actor } && latestHook?.healthy == true
    return DoctorCheck(
      id: "install.claude.session", status: observed ? .pass : .warning,
      message: (observed
        ? "Claude SILTA_SESSION propagation observed in an ordinary command "
          + "in the latest hook session."
        : "Claude SILTA_SESSION propagation not established in the latest hook session "
          + "(missing, legacy, mismatched or incomplete evidence).") + detail,
      next: observed ? [] : next, nextBy: .human)
  }

  private struct EvidenceProblem: Error {  // guard:allow-error local scan control
    let path: URL
    let reason: String

    func next(home: URL) -> [String] {
      let file = shellWord(path.path)
      return [
        "/bin/ls -ld " + file,
        "# Choose an absent backup path outside the log directory; preserve evidence first.\n"
          + "/bin/cp -pRPn " + file + " '<new-backup-path>'",
        "# Inspect the preserved copy; decide whether to quarantine to an absent new path.\n"
          + "/bin/mv -n " + file + " '<new-quarantine-path>'",
        "SILTA_HOME=" + shellWord(home.path) + " silta doctor --install",
      ]
    }
  }

  private static func read(home: URL, at now: Date) throws -> [Entry] {
    var entries: [Entry] = []
    let names = try inventory(home: home, at: now)
    var total = 0
    for name in names {
      let path = home.appending(path: "log/" + name)
      let text = try readFile(home: home, name: name, at: now)
      total += text.utf8.count
      guard total <= 16 * 1_048_576 else {
        throw EvidenceProblem(
          path: home.appending(path: "log"),
          reason: "Retained log data exceeds the 16 MiB aggregate limit.")
      }
      do { entries += try parse(text, name: name, at: now) } catch {
        throw EvidenceProblem(
          path: path, reason: "Retained log contains invalid command records or timestamps.")
      }
    }
    return entries.enumerated().sorted {
      if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
      return $0.element.timestamp < $1.element.timestamp
    }.map(\.element)
  }

  private static func inventory(home: URL, at now: Date) throws -> [String] {
    let path = home.appending(path: "log")
    let root = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if root < 0, errno == ENOENT { return [] }
    guard root >= 0 else {
      throw EvidenceProblem(path: path, reason: "Cannot safely open the log home.")
    }
    defer { close(root) }
    let descriptor = openat(root, "log", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT { return [] }
    guard descriptor >= 0 else {
      throw EvidenceProblem(path: path, reason: "Cannot safely open the log directory.")
    }
    guard let stream = fdopendir(descriptor) else {
      close(descriptor)
      throw EvidenceProblem(path: path, reason: "Cannot inspect the log directory.")
    }
    defer { closedir(stream) }
    let oldest = utcDay(now.addingTimeInterval(-Double(SystemLog.retainedDays - 1) * 86400))
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? ""
      }
      if name.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl/) != nil, name >= oldest + ".jsonl"
      {
        names.append(name)
        guard names.count <= SystemLog.retainedDays else {
          throw EvidenceProblem(
            path: path, reason: "Retained log inventory exceeds the 90-file limit.")
        }
      }
      errno = 0
    }
    guard errno == 0 else {
      throw EvidenceProblem(path: path, reason: "Retained log inventory is incomplete.")
    }
    return names.sorted()
  }

  private static func readFile(home: URL, name: String, at now: Date) throws -> String {
    let path = home.appending(path: "log/" + name)
    guard name <= utcDay(now) + ".jsonl" else {
      throw EvidenceProblem(path: path, reason: "Retained log filename is future-dated.")
    }
    let text: String
    do {
      guard let value = try AgentHealthFiles.read(root: home.path, path: "log/" + name) else {
        throw TaskError.input
      }
      text = value
    } catch {
      throw EvidenceProblem(
        path: path,
        reason: "Cannot safely read the retained log as a regular UTF-8 file of at most 1 MiB.")
    }
    guard text.isEmpty || text.hasSuffix("\n") else {
      throw EvidenceProblem(path: path, reason: "Retained log has an incomplete final record.")
    }
    return text
  }

  private static func parse(_ text: String, name: String, at now: Date) throws -> [Entry] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try text.split(separator: "\n").map { line in
      let entry = try decoder.decode(Entry.self, from: Data(line.utf8))
      guard let date = utcInstant(entry.timestamp), date <= now,
        utcDay(date) + ".jsonl" == name,
        ActorID.parse(entry.actor) != nil, entry.milliseconds >= 0
      else { throw TaskError.input }
      return entry
    }
  }
}
