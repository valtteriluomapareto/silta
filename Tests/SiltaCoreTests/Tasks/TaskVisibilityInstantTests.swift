import Foundation
import Testing

@testable import SiltaCore

struct TaskVisibilityInstantTests {
  /// The arithmetic fast path must agree bit for bit with the formatter it replaces,
  /// or archive boundaries would move.
  @Test func canonicalInstantMatchesFormatter() throws {
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    var state: UInt64 = 0x5EED
    var samples = [
      "1970-01-01T00:00:00.000Z", "2000-02-29T23:59:59.999Z", "2023-11-14T22:13:20.000Z",
      "2023-11-14T22:13:20.001Z", "2024-12-31T00:00:00.500Z", "2100-03-01T12:00:00.123Z",
    ]
    for _ in 0..<5000 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let milliseconds = Int64(state >> 22) % 4_102_444_800_000
      samples.append(utcTimestamp(Date(timeIntervalSince1970: Double(milliseconds) / 1000)))
    }
    for sample in samples {
      let expected = try style.parse(sample).timeIntervalSince1970
      #expect(TaskVisibility.canonicalInstant(sample) == expected, "\(sample)")
    }
  }

  @Test(arguments: [
    "2023-02-29T00:00:00.000Z", "2023-13-01T00:00:00.000Z", "2023-11-14T24:00:00.000Z",
    "2023-11-14T22:60:00.000Z", "2023-11-14T22:13:20Z", "2023-11-14T22:13:20.000+01:00",
    "0000-01-01T00:00:00.000Z", "2023-11-14 22:13:20.000Z", "2023-11-1４T22:13:20.000Z",
  ])
  func nonCanonicalTextTakesTheFormatter(_ text: String) {
    #expect(TaskVisibility.canonicalInstant(text) == nil)
  }
}
