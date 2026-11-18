public import Foundation
import SiltaCore

/// The app's writes as `human:<USER>`: one SiltaCore service call per action, on the
/// existing store only, so the app never creates or migrates one (D50).
public struct AppWriter: Sendable {
  private let base: SiltaEnvironment

  /// Shares the reader's data home, human identity and clock.
  public init(reader: AppReader) {
    base = reader.environment
  }

  /// Runs one write and logs one body-free line for it. Failures throw `AppReadError`;
  /// store refusals keep their kinds and everything else keeps Core's code.
  public func perform(_ write: AppWrite, workspace: String) throws {
    let started = base.clock.now()
    var failure: ErrorCode?
    defer { log(write, workspace: workspace, started: started, failure: failure) }
    do {
      try AppReader.checked(home: base.home.url) {
        let environment = environment()
        // Opening first makes store refusals win over the service's workspace lookup.
        try environment.db.initialize()
        let service = TaskService(environment: environment, workspace: workspace)
        switch write {
        case .answer(let task, let question, let body):
          var draft = CommentDraft(body: body, kind: "answer")
          draft.replyTo = question
          _ = try service.comment(task, draft)
        case .comment(let task, let body):
          _ = try service.comment(task, CommentDraft(body: body))
        case .acceptAnswer(let ref):
          _ = try service.acceptComment(ref)
        }
      }
    } catch let error as AppReadError {
      failure = error.code
      throw error
    }
  }

  /// A fresh existing-only store per write, so a cached connection never outlives a
  /// store that was replaced or removed.
  private func environment() -> SiltaEnvironment {
    SiltaEnvironment(
      clock: base.clock, ids: base.ids, git: base.git, home: base.home,
      db: DatabaseStore(home: base.home.url, clock: base.clock, jitter: { 0 }, existingOnly: true),
      log: base.log, actor: base.actor, human: base.human)
  }

  /// Logs into an existing data home only; a refused missing store stays absent.
  private func log(_ write: AppWrite, workspace: String, started: Date, failure: ErrorCode?) {
    guard FileManager.default.fileExists(atPath: base.home.url.path) else { return }
    var entry = LogEntry(
      timestamp: started, command: write.logCommand, actor: base.actor.description,
      exitCode: failure?.exitCode ?? 0,
      milliseconds: max(0, Int(base.clock.now().timeIntervalSince(started) * 1000)))
    entry.workspace = workspace
    entry.errorCode = failure
    SystemLog(directory: base.home.url.appending(path: "log")).record(entry)
  }
}
