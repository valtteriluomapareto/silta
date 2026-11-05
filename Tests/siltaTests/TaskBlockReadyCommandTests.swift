import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct TaskBlockReadyCommandTests {
  @Test func textReadinessAndConditionalRecovery() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          args + ["--deterministic"], in: scratch,
          environment: TaskBlockCommandTests.environment)
      }
      for title in ["Acme waiting", "Acme prerequisite"] {
        #expect(try run(["task", "add", title, "--start"]).termination == .exit(0))
      }
      #expect(
        try run(["task", "block", "AC-1", "--on", "AC-2", "-m", "Acme prerequisite"]).termination
          == .exit(0))
      #expect(try !run(["task", "show", "AC-1"]).stdout.contains("Ready to unblock."))
      #expect(try run(["task", "done", "AC-2", "-m", "Acme finished"]).termination == .exit(0))
      for args in [["task", "show", "AC-1"], ["task", "ls", "--status", "blocked"]] {
        #expect(try run(args).stdout.contains("Ready to unblock."))
      }
      let refused = try run(["task", "start", "AC-1"])
      #expect(refused.termination == .exit(6))
      #expect(refused.stderr.contains("silta --ws 'acme' task unblock AC-1"))
      #expect(
        try run(["task", "show", "AC-1", "--json"]).stdout.contains("\"status\":\"blocked\""))
    }
  }

  @Test func invalidUnblockApprovalRecoveryDoesNotEchoCredentials() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let secret = "Pwd=" + "acme-secret"
      let result = try SiltaBinary.run(
        ["task", "unblock", secret, "--allow-secret", "-m", "Acme"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(3))
      #expect(!(result.stdout + result.stderr).contains("acme-secret"))
    }
  }
}
