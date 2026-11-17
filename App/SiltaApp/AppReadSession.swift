import Foundation
import SiltaAppSupport
import Synchronization

nonisolated final class AppReadSession: Sendable {
  private let reader: AppReader
  private let now: @Sendable () -> Date
  private let probe = Mutex<AppChangeProbe?>(nil)

  init(reader: AppReader, now: @escaping @Sendable () -> Date = { Date() }) {
    self.reader = reader
    self.now = now
  }

  func load(previous: AppLoadedData?, workspace: String?, force: Bool) throws -> AppLoadedData? {
    let connection = try probe.withLock { cached in
      if let cached { return cached }
      let opened = try reader.makeChangeProbe()
      cached = opened
      return opened
    }
    let version = try connection.version()
    let at = now()
    if !force, let previous, previous.workspace == workspace, previous.version == version,
      at >= previous.checkedAt,
      at
        < min(
          previous.snapshot?.validUntil ?? .distantFuture,
          previous.checkedAt.addingTimeInterval(60))
    {
      return nil
    }
    let workspaces = try reader.workspaces()
    let selected = workspace ?? workspaces.first?.slug
    let snapshot = try selected.map { try reader.snapshot(workspace: $0) }
    let map = try selected.map { try reader.workspaceMap(workspace: $0) }
    return AppLoadedData(
      workspaces: workspaces, workspace: selected, snapshot: snapshot,
      map: map, version: version, checkedAt: now())
  }
}
