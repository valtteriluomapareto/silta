/// An unhealthy diagnostic report. Its checks remain in the command's data.
package struct DoctorFailure: CodedError {
  /// The full report; independent failures are not collapsed into one cause.
  package let report: DoctorReport

  /// Retains diagnostic evidence while reporting the standard environment error.
  package init(report: DoctorReport) { self.report = report }

  package var code: ErrorCode { .env }
  package var message: String {
    "Doctor found failed checks: "
      + report.checks.filter { $0.status == .fail }.map(\.id).joined(separator: ", ") + "."
  }
  package var nextBy: NextBy {
    report.checks.first { $0.status == .fail }?.nextBy ?? .agent
  }

  /// Top-level recovery starts at the first failure; each check has its own next commands.
  package var next: [String] {
    report.checks.first { $0.status == .fail }?.next ?? ["silta init"]
  }
}
