/// A read-only diagnostic report, including checks that could not run.
package struct DoctorReport: Encodable, Sendable {
  /// Checks in the fixed order documented in spec §19.
  package var checks: [DoctorCheck]

  /// Assembles ordered checks, including CLI-owned installation diagnostics.
  package init(checks: [DoctorCheck]) { self.checks = checks }

  /// The complete text report, with action ownership and bounded command lists.
  package var text: String {
    checks.map { check in
      let verb = check.nextBy == .human ? "ask human" : "next"
      return "\(check.status.rawValue): \(check.id): \(check.message)\n"
        + check.next.map { "  \(verb): \($0)\n" }.joined()
        + (check.nextOmitted > 0 ? "  +\(check.nextOmitted) more\n" : "")
    }.joined()
  }
}
