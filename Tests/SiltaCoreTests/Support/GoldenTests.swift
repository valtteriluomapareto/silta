import Foundation
import SiltaTestSupport
import Testing

struct GoldenTests {
  @Test func matchingGoldenPasses() throws {
    try withScratchDirectory { dir in
      try Data("a\nb\n".utf8).write(to: dir.appending(path: "x.txt"))
      Golden(directory: dir, update: false).check("a\nb\n", "x.txt")
    }
  }

  @Test func mismatchIsAnIssue() throws {
    try withScratchDirectory { dir in
      try Data("a\nb\n".utf8).write(to: dir.appending(path: "x.txt"))
      withKnownIssue {
        Golden(directory: dir, update: false).check("a\nc\n", "x.txt")
      }
    }
  }

  // "é" precomposed and decomposed are equal as Swift strings but differ as bytes.
  @Test func comparisonIsByteForByte() throws {
    try withScratchDirectory { dir in
      try Data("\u{E9}\n".utf8).write(to: dir.appending(path: "x.txt"))
      withKnownIssue {
        Golden(directory: dir, update: false).check("e\u{301}\n", "x.txt")
      }
    }
  }

  @Test func missingGoldenIsAnIssue() throws {
    try withScratchDirectory { dir in
      withKnownIssue {
        Golden(directory: dir, update: false).check("a\n", "missing.txt")
      }
      #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "missing.txt").path))
    }
  }

  @Test func updateModeWritesTheFileAndStillRecordsAnIssue() throws {
    try withScratchDirectory { dir in
      withKnownIssue {
        Golden(directory: dir, update: true).check("new\n", "x.txt")
      }
      #expect(try Data(contentsOf: dir.appending(path: "x.txt")) == Data("new\n".utf8))
    }
  }

  @Test func defaultDirectoryIsTheTestTargetsGoldenFolder() {
    #expect(Golden.forTests().directory.path.hasSuffix("/Tests/SiltaCoreTests/Golden"))
  }
}
