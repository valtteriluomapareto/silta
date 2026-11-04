import Foundation
@testable import SiltaCore
import Testing

struct ClockTests {
  @Test(arguments: 0...999)
  func canonicalUTCTimestampsAcceptEveryMillisecond(millisecond: Int) throws {
    let raw = String(format: "2023-11-14T22:13:20.%03dZ", millisecond)
    let date = try #require(utcInstant(raw))
    let stamped = Int((date.timeIntervalSince1970 * 1000).rounded())
    #expect(stamped == 1_700_000_000_000 + millisecond)
  }

  @Test(
    arguments: [
      "2023-11-14T22:13:20Z", "2023-11-14T22:13:20.1Z", "2023-11-14T22:13:20.12Z",
      "2023-11-14T22:13:20.1234Z", "2023-11-14T22:13:20.123+02:00",
      "2023-11-14T22:13:20.123+00:00", "2023-11-14T22:13:20.123z",
      "2023-11-14T22:13:20.123", "2023-11-14 22:13:20.123Z",
      "2023-11-14T22:13:20.123ZZ", "2026-02-30T15:21:11.859Z",
      "2026-13-04T15:21:11.859Z", "2026-11-04T25:21:11.859Z",
      "2026-11-04T15:61:11.859Z", "2026-11-04T15:21:61.859Z",
      "0000-01-01T00:00:00.000Z", "garbage", "",
    ])
  func nonCanonicalTimestampsAreRejected(raw: String) {
    #expect(utcInstant(raw) == nil)
  }
}
