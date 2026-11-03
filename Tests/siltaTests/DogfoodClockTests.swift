import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DogfoodClockTests {
  @Test func reportClockKeepsCallsFromItsCurrentSecond() throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      try DogfoodReportTests.tool(
        "date",
        text: """
          #!/bin/bash
          case "$*" in
            '-u +%Y-%m-%dT%H:%M:%SZ') echo 2023-11-30T00:00:00Z;;
            '-u +%Y-%m-%dT%H:%M:%S.%NZ') echo 2023-11-30T00:00:00.750000000Z;;
            *) exec /bin/date "$@";;
          esac
          """, in: tools)
      let entry: [String: Any] = [
        "timestamp": "2023-11-30T00:00:00.500Z", "workspace": "silta",
        "actor": DogfoodReportTests.actor, "command": "silta task show",
        "exit_code": 0, "milliseconds": 1, "warnings": [],
      ]
      let data = try JSONSerialization.data(withJSONObject: entry)
      try (data + Data("\n".utf8)).write(
        to: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let result = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      withKnownIssue("The report clock truncates current-second calls") {
        #expect(result.stdout.contains("| silta task show | 1 | 0% |"))
      }
    }
  }
}
