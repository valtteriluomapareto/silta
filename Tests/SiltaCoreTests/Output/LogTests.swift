import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct LogTests {
  private let entry = LogEntry(
    timestamp: Date(timeIntervalSince1970: 1_700_000_000), command: "task.add", actor: "agent:acme:1",
    exitCode: 0, milliseconds: 12)

  @Test(arguments: [false, true]) func logContract(fake: Bool) throws {
    try withScratchDirectory { scratch in
      let capture = FakeLog()
      let system = SystemLog(directory: scratch)
      let log: any Log = fake ? capture : system
      try log.record(entry)
      try log.record(entry)
      if fake {
        #expect(capture.entries == [entry, entry])
      } else {
        let lines = try String(contentsOf: scratch.appending(path: "2023-11-14.jsonl"), encoding: .utf8)
          .split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == lines[1])
        let json = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
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
      try log.record(entry)
      #expect(try Data(contentsOf: output) == Data(contentsOf: directory.appending(path: "2023-11-14.jsonl")))
      var tomorrow = entry
      tomorrow.timestamp = entry.timestamp.addingTimeInterval(86400)
      try log.record(tomorrow)
      #expect(FileManager.default.fileExists(atPath: directory.appending(path: "2023-11-15.jsonl").path))
      #expect(throws: (any Error).self) { try SystemLog(directory: output).record(entry) }
    }
  }
}
