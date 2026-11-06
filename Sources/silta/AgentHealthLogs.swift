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
    var complete = true
    do { entries = try read(home: home, at: now) } catch { complete = false }
    let next = [AgentHealth.acceptance]
    var checks = [
      ("silta agents session-start", "install.claude.session_start", "SessionStart"),
      ("silta agents stop", "install.claude.last_stop", "Stop"),
    ].map { command, id, label in
      let entry = entries.last { $0.command == command }
      let detail =
        entry.map {
          "Last Claude \(label): \($0.timestamp), exit \($0.exitCode), \($0.milliseconds) ms; "
            + ($0.healthy
              ? "no logged error or warning." : "logged failure, warning or unexpected actor.")
        } ?? "Claude \(label): no retained hook record."
      return DoctorCheck(
        id: id, status: complete && entry?.healthy == true ? .pass : .warning,
        message: detail
          + (complete ? "" : " Retained log evidence is incomplete or invalid; health is unknown."),
        next: complete && entry?.healthy == true ? [] : next, nextBy: .human)
    }
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
      && latestHook?.actor == start.map { entries[$0].actor }
    checks.append(
      DoctorCheck(
        id: "install.claude.session", status: observed ? .pass : .warning,
        message: observed
          ? "Claude SILTA_SESSION propagation observed in an ordinary command "
            + "in the latest hook session."
          : "Claude SILTA_SESSION propagation not established in the latest hook session "
            + "(missing, legacy, mismatched or incomplete evidence).",
        next: observed ? [] : next, nextBy: .human))
    return checks
  }

  private static func read(home: URL, at now: Date) throws -> [Entry] {
    var entries: [Entry] = []
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let directory = home.appending(path: "log")
    let files: [String]
    do { files = try FileManager.default.contentsOfDirectory(atPath: directory.path) } catch {
      if (error as NSError).code == NSFileReadNoSuchFileError { files = [] } else { throw error }
    }
    let oldest = utcDay(now.addingTimeInterval(-Double(SystemLog.retainedDays - 1) * 86400))
    let names = files.filter {
      $0.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl/) != nil && $0 >= oldest + ".jsonl"
    }.sorted()
    guard names.count <= SystemLog.retainedDays else { throw TaskError.input }
    var total = 0
    for name in names {
      guard name <= utcDay(now) + ".jsonl",
        let text = try AgentHealthFiles.read(root: home.path, path: "log/" + name),
        text.isEmpty || text.hasSuffix("\n")
      else { throw TaskError.input }
      total += text.utf8.count
      guard total <= 16 * 1_048_576 else { throw TaskError.input }
      for line in text.split(separator: "\n") {
        let entry = try decoder.decode(Entry.self, from: Data(line.utf8))
        guard let date = utcInstant(entry.timestamp), date <= now,
          utcDay(date) + ".jsonl" == name,
          ActorID.parse(entry.actor) != nil, entry.milliseconds >= 0
        else { throw TaskError.input }
        entries.append(entry)
      }
    }
    return entries.enumerated().sorted {
      if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
      return $0.element.timestamp < $1.element.timestamp
    }.map(\.element)
  }

}
