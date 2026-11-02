import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ControlPlaneRecoveryTests {
  @Test(
    arguments: [["--help", "--json"], ["--version", "--json"], ["schema", "--help"], []],
    [false, true])
  func helpAndVersionWorkWithInvalidConfiguration(arguments: [String], invalidHome: Bool) throws {
    try withScratchDirectory { scratch in
      let environment = invalidHome ? ["SILTA_HOME": "relative"] : ["SILTA_NOW": "bad"]
      let result = try SiltaBinary.run(arguments, in: scratch, environment: environment)

      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      #expect(
        result.stdout.hasPrefix(
          arguments.contains("--version") ? SiltaVersion.current : "OVERVIEW:"))
    }
  }
}
