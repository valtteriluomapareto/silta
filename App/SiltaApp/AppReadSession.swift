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
    let (version, reused) = try probe.withLock { cached in
      do {
        let reused = cached != nil
        let connection: AppChangeProbe
        if let cached {
          connection = cached
        } else {
          connection = try reader.makeChangeProbe()
          cached = connection
        }
        return (try connection.version(), reused)
      } catch {
        cached = nil
        throw error
      }
    }
    let at = now()
    if !force, reused, let previous, previous.workspace == workspace,
      previous.version == version, at >= previous.checkedAt,
      at < previous.checkedAt.addingTimeInterval(60)
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
