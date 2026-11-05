import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DoctorCommandTests {
  private let environment = ["SILTA_NOW": "2023-11-14T22:13:20.000Z"]

  private func normalize(_ text: String, _ scratch: URL) -> String {
    text.replacingOccurrences(of: scratch.appending(path: "silta-home").path, with: "<silta-home>")
  }

  @Test func initializedDatabaseHasNoFailedChecksAndQuietKeepsTheReport() throws {
    try withScratchDirectory { scratch in
      try #require(
        SiltaBinary.run(["init"], in: scratch, environment: environment).termination == .exit(0))
      for flags in [[], ["--quiet"]] {
        let result = try SiltaBinary.run(["doctor"] + flags, in: scratch, environment: environment)
        #expect(result.termination == .exit(0))
        Golden.forTests().check(normalize(result.stdout, scratch), "doctor.txt")
        #expect(result.stderr.isEmpty)
      }
      let result = try SiltaBinary.run(["doctor", "--json"], in: scratch, environment: environment)
      Golden.forTests().check(normalize(result.stdout, scratch), "doctor.json")
      #expect(result.termination == .exit(0))
    }
  }

  @Test func missingDatabaseReportsAllChecksWithoutInitializing() throws {
    try withScratchDirectory { scratch in
      for flags in [["--json"], ["--json", "--quiet"]] {
        let result = try SiltaBinary.run(["doctor"] + flags, in: scratch, environment: environment)
        #expect(result.termination == .exit(9))
        Golden.forTests().check(normalize(result.stdout, scratch), "doctor-missing.json")
        #expect(result.stderr.isEmpty)
      }
      let result = try SiltaBinary.run(["doctor"], in: scratch, environment: environment)
      Golden.forTests().check(normalize(result.stdout, scratch), "doctor-missing.txt")
      Golden.forTests().check(result.stderr, "doctor-missing-error.txt")
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
      let log = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      for line in log.split(separator: "\n") {
        let entry = try #require(
          JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(entry["command"] as? String == "silta doctor")
        #expect(entry["error_code"] as? String == "env")
        #expect(entry["workspace"] == nil)
      }
    }
  }
}
