/// The hook's process deadline (spec §12), measured from process start by the caller.
/// Every hook timing decision comes from here; this type never reads a clock itself.
package struct BriefHookDeadline: Sendable {
  /// The whole hook process, including environment assembly and output. The process
  /// watchdog alone enforces it; completion never re-checks the clock.
  package static let budget: Duration = .milliseconds(1500)
  /// Child Git reads stop this long before the process deadline. Utility workers can
  /// coalesce timeout wakeups, so the reserve leaves time to terminate and reap.
  package static let childReserve: Duration = .milliseconds(500)

  private let elapsed: @Sendable () -> Duration

  /// `elapsed` reports monotonic time since the hook process started.
  package init(elapsed: @escaping @Sendable () -> Duration) {
    self.elapsed = elapsed
  }

  /// Seconds a child read may still take; zero or less means it must not start.
  package var childSeconds: Double {
    let left = (Self.budget - Self.childReserve - elapsed()).components
    return Double(left.seconds) + Double(left.attoseconds) / 1e18
  }
}
