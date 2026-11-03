import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct CommandDiagnosticTests {
  @Test(arguments: [false, true]) func renderedWarningsRetainCodesOnly(json: Bool) {
    let output = CommandOutput(
      text: "Acme", data: "Acme",
      warnings: [OutputWarning(code: "ref_stale", message: "Acme private warning")])
    let rendered = OutputRouter.render(.success(output), mode: OutputMode(json: json))
    #expect(rendered.warningCodes == ["ref_stale"])
  }

  @Test func logsKeepNinetyDaysAndPreserveUnrelatedEntries() throws {
    try withScratchDirectory { directory in
      for day in ["2023-08-17", "2023-08-18", "2023-11-14", "2023-11-15"] {
        try Data().write(to: directory.appending(path: "\(day).jsonl"))
      }
      try Data("Acme".utf8).write(to: directory.appending(path: "0000-Acme.txt"))
      let folder = directory.appending(path: "2000-01-01.jsonl")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let entry = LogEntry(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + 86400), command: "schema",
        actor: "agent:unknown:acme", exitCode: 0, milliseconds: 0)
      SystemLog(directory: directory).record(entry)
      let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(!files.contains("2023-08-17.jsonl"))
      #expect(files.contains("2023-08-18.jsonl"))
      #expect(files.contains("2023-11-14.jsonl"))
      #expect(files.contains("2023-11-15.jsonl"))
      #expect(files.contains("0000-Acme.txt"))
      #expect(files.contains("2000-01-01.jsonl"))
    }
  }
}
