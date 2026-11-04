/// A read-only diagnostic report, including checks that could not run.
package struct DoctorReport: Encodable, Sendable {
  /// Checks in display order, with independent failures retained.
  package var checks: [DoctorCheck]

  /// The same complete report in text mode, including under --quiet.
  package var text: String {
    checks.map { check in
      "\(check.status): \(check.id): \(check.message)\n"
        + check.next.map { "  next: \($0)\n" }.joined()
    }.joined()
  }
}

/// One diagnostic result. Recovery commands inspect state; they never authorize repairs.
package struct DoctorCheck: Encodable, Sendable {
  /// Stable check identifier.
  package let id: String
  /// One of pass, warning, fail or skipped.
  package let status: String
  /// Body-free explanation of the result.
  package let message: String
  /// Recovery or inspection commands for this check alone.
  package var next: [String] = []
}
