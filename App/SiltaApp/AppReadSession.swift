import Foundation
import SiltaAppSupport

nonisolated final class AppReadSession: Sendable {
  let reader: AppReader
  let now: @Sendable () -> Date

  init(reader: AppReader, now: @escaping @Sendable () -> Date = { Date() }) {
    self.reader = reader
    self.now = now
  }

  func load(previous: AppLoadedData?, workspace: String?, force: Bool) throws -> AppLoadedData? { nil }
}
