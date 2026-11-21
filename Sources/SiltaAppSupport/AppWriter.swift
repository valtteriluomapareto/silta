import Foundation
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
  /// Returns the created task's reference for `createTask`, and nil for every other write.
  /// The app sends every write through `send`; writes that close a task need it.
  @discardableResult
  public func perform(_ write: AppWrite, workspace: String) throws -> String? {
    let started = base.clock.now()
    var failure: ErrorCode?
    defer { log(write, workspace: workspace, started: started, failure: failure) }
    do {
      return try AppReader.checked(home: base.home.url) { () throws -> String? in
        try run(write, service: openService(workspace))
      }
    } catch let error as AppReadError {
      failure = error.code
      throw error
    }
  }

  /// Runs any write, including those that close a task, which Core runs asynchronously.
  @discardableResult
  public func send(_ write: AppWrite, workspace: String) async throws -> String? {
    guard case .dropTask(let ref, let why) = write else {
      return try perform(write, workspace: workspace)
    }
    let started = base.clock.now()
    var failure: ErrorCode?
    defer { log(write, workspace: workspace, started: started, failure: failure) }
    do {
      do {
        let service = try openService(workspace)
        _ = try await service.close(
          ref, result: why, dropped: true, directory: base.home.url)
        return nil
      } catch {
        throw AppReadError(error).scoped(to: base.home.url)
      }
    } catch let error as AppReadError {
      failure = error.code
      throw error
    }
  }

  /// Opens the existing store first, so store refusals win over the service's workspace
  /// lookup.
  private func openService(_ workspace: String) throws -> TaskService {
    let environment = environment()
    try environment.db.initialize()
    return TaskService(environment: environment, workspace: workspace)
  }

  private func run(_ write: AppWrite, service: TaskService) throws -> String? {
    switch write {
    case .answer, .comment, .resolveThreads, .reopenThreads, .acceptAnswer:
      try discuss(write, service: service)
    case .acceptProposals, .dropProposals, .unblock, .unblockAnyway, .snooze:
      try organize(write, service: service)
    case .dropTask:
      throw StorageError.internalMisuse
    case .createTask(let task):
      var draft = TaskDraft(title: task.title)
      draft.description = task.description
      draft.acceptance = task.acceptance
      draft.app = task.app
      draft.parent = task.parent
      draft.priority = task.priority
      return try service.addUnstarted(draft).ref
    }
    return nil
  }

  private func discuss(_ write: AppWrite, service: TaskService) throws {
    switch write {
    case .answer(let task, let question, let body):
      var draft = CommentDraft(body: body, kind: "answer")
      draft.replyTo = question
      _ = try service.comment(task, draft)
    case .comment(let task, let body, let replyTo, let kind, let recipients):
      var draft = CommentDraft(body: body, kind: kind == "comment" ? nil : kind)
      draft.replyTo = replyTo
      draft.recipients = recipients
      _ = try service.comment(task, draft)
    case .resolveThreads(let refs):
      _ = try service.updateComments(refs, action: .resolve)
    case .reopenThreads(let refs):
      _ = try service.updateComments(refs, action: .reopen)
    case .acceptAnswer(let ref):
      _ = try service.acceptComment(ref)
    default:
      throw StorageError.internalMisuse
    }
  }

  private func organize(_ write: AppWrite, service: TaskService) throws {
    switch write {
    case .acceptProposals(let refs):
      var batch = TaskTriage()
      batch.accept = refs
      _ = try service.triage(batch)
    case .dropProposals(let refs, let why):
      var batch = TaskTriage()
      batch.drop = refs
      batch.why = why
      _ = try service.triage(batch)
    case .unblock(let ref):
      _ = try service.unblock([ref], requireReady: true)
    case .unblockAnyway(let ref, let confirmed):
      let open = try service.unmetBlockers([ref])[ref]?.open ?? []
      guard Set(open) == Set(confirmed) else { throw TaskError.edited(ref) }
      _ = try service.unblock([ref])
    case .snooze(let ref, let days):
      let task = try service.show(ref)
      guard let why = task.waiting?.why else {
        throw TaskError.transition(ref, status: task.status)
      }
      var block = TaskBlock(why: why)
      block.followUp = "\(days)d"
      _ = try service.block(ref, block)
    default:
      throw StorageError.internalMisuse
    }
  }

  /// A fresh existing-only store per write, so a cached connection never outlives a
  /// store that was replaced or removed. Busy retries use the CLI's jitter, so the app
  /// and a CLI process don't retry in lockstep.
  private func environment() -> SiltaEnvironment {
    SiltaEnvironment(
      clock: base.clock, ids: base.ids, git: base.git, home: base.home,
      db: DatabaseStore(
        home: base.home.url, clock: base.clock, jitter: { UInt64.random(in: 10...50) },
        existingOnly: true),
      log: base.log, actor: base.actor, human: base.human)
  }

  /// Logs only beside an existing store, so a refused missing store leaves nothing behind.
  private func log(_ write: AppWrite, workspace: String, started: Date, failure: ErrorCode?) {
    guard FileManager.default.fileExists(atPath: base.db.path) else { return }
    var entry = LogEntry(
      timestamp: started, command: write.logCommand, actor: base.actor.description,
      exitCode: failure?.exitCode ?? 0,
      milliseconds: max(0, Int(base.clock.now().timeIntervalSince(started) * 1000)))
    entry.workspace = workspace
    entry.errorCode = failure
    SystemLog(directory: base.home.url.appending(path: "log")).record(entry)
  }
}
