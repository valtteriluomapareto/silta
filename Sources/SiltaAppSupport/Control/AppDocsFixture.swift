#if DEBUG
  public import Foundation
  import SiltaCore

  /// Private synthetic tasks plus document histories, proposals, legacy and archived data.
  public enum AppDocsFixture {
    /// Creates an absent isolated home using the shared task seed and Core document writer.
    public static func seed(home: URL) throws {
      try AppV2Fixture.seed(home: home)
      let clock = IncrementingClock(start: AppV2Fixture.now)
      let ids = SeededIDGenerator(seed: 1403)
      let store = DatabaseStore(home: home, clock: clock, jitter: { 0 })
      try store.write { try DebugDocumentFixture.insert(in: $0, ids: ids, at: AppV2Fixture.now) }

    }
  }
#endif
