import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct LogTests {
  private let entry = LogEntry(
    timestamp: Date(timeIntervalSince1970: 1_700_000_000), command: "task.add",
    actor: "agent:acme:1",
    exitCode: 0, milliseconds: 12)

  @Test(arguments: [false, true]) func logContract(fake: Bool) throws {
    try withScratchDirectory { scratch in
      let capture = FakeLog()
      let system = SystemLog(directory: scratch)
      let log: any Log = fake ? capture : system
      log.record(entry)
      log.record(entry)
      if fake {
        #expect(capture.entries == [entry, entry])
      } else {
        let lines = try String(
          contentsOf: scratch.appending(path: "2023-11-14.jsonl"), encoding: .utf8
        )
        .split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == lines[1])
        let json = try #require(
          JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(json["command"] as? String == "task.add")
        #expect(json["timestamp"] as? String == "2023-11-14T22:13:20.000Z")
        #expect(json["body"] == nil)
        #expect(json["arguments"] == nil)
      }
    }
  }

  @Test func verboseMirrorsJSONLAndInjectedTimeRollsDay() throws {
    try withScratchDirectory { scratch in
      let output = scratch.appending(path: "stderr")
      #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
      let handle = try FileHandle(forWritingTo: output)
      defer { try? handle.close() }  // best-effort cleanup of a test handle
      let directory = scratch.appending(path: "log")
      let log = SystemLog(directory: directory, verbose: handle)
      log.record(entry)
      #expect(
        try Data(contentsOf: output)
          == Data(contentsOf: directory.appending(path: "2023-11-14.jsonl")))
      var tomorrow = entry
      tomorrow.timestamp = entry.timestamp.addingTimeInterval(86400)
      log.record(tomorrow)
      #expect(
        FileManager.default.fileExists(atPath: directory.appending(path: "2023-11-15.jsonl").path))
      SystemLog(directory: output).record(entry)
    }
  }
  @Test func failedLogWriteCannotFailASuccessfulCommand() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "not-a-directory")
      try Data().write(to: file)
      let result = CommandOutput(text: "done", data: "done")
      let log: any Log = SystemLog(directory: file)
      log.record(entry)
      #expect(OutputRouter.render(.success(result), mode: OutputMode(json: false)).exitCode == 0)
    }
  }

  @Test func logSchemaUsesSnakeCaseAndTypedErrorCodes() throws {
    try withScratchDirectory { scratch in
      var failed = entry
      failed.exitCode = 9
      failed.errorCode = .env
      failed.workspace = "acme"
      failed.app = "api"
      failed.flags = ["--json"]
      failed.warnings = ["ref_stale"]
      SystemLog(directory: scratch).record(failed)
      let data = try Data(contentsOf: scratch.appending(path: "2023-11-14.jsonl"))
      let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(
        Set(json.keys) == [
          "timestamp", "command", "actor", "exit_code", "milliseconds",
          "error_code", "workspace", "app", "flags", "busy_retries", "git_calls",
          "git_milliseconds",
          "warnings",
        ])
      #expect(json["error_code"] as? String == "env")
      #expect(json["exit_code"] as? Int == 9)
      #expect(json["flags"] as? [String] == ["--json"])
      #expect(json["warnings"] as? [String] == ["ref_stale"])
    }
  }

  @Test func verboseWriteFailureIsBestEffort() throws {
    try withScratchDirectory { scratch in
      let output = scratch.appending(path: "stderr")
      try Data().write(to: output)
      let closed = try FileHandle(forWritingTo: output)
      try closed.close()
      let log: any Log = SystemLog(directory: scratch, verbose: closed)
      log.record(entry)
      let lines = try String(
        contentsOf: scratch.appending(path: "2023-11-14.jsonl"), encoding: .utf8)
      #expect(lines.split(separator: "\n").count == 1)
    }
  }

}
