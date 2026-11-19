#if DEBUG
  @testable import SiltaApp
  import Testing

  struct SeaInspectorMetricsTests {
    @Test func widthStaysWithinTheColumnRange() {
      #expect(SeaInspectorMetrics.clamped(SeaInspectorMetrics.width) == 340)
      #expect(SeaInspectorMetrics.clamped(120) == 300)
      #expect(SeaInspectorMetrics.clamped(900) == 500)
      #expect(SeaInspectorMetrics.range.contains(SeaInspectorMetrics.width))
    }

    @Test func draggingLeftWidensAndRightNarrowsWithinTheRange() {
      #expect(SeaInspectorMetrics.resized(from: 340, translation: -60) == 400)
      #expect(SeaInspectorMetrics.resized(from: 340, translation: 30) == 310)
      #expect(SeaInspectorMetrics.resized(from: 340, translation: -400) == 500)
      #expect(SeaInspectorMetrics.resized(from: 340, translation: 400) == 300)
    }

    @Test func aStoredWidthOutsideTheRangeStartsFromItsClampedValue() {
      #expect(SeaInspectorMetrics.resized(from: 900, translation: 20) == 480)
      #expect(SeaInspectorMetrics.resized(from: 10, translation: -20) == 320)
    }
  }
#endif
