import Foundation
import SiltaTestSupport
import Testing

/// Regressions for code reads: regex flavour, bounds, decoding, attributes, refs and paths.
extension CodeCommandTests {
  @Test func grepUsesExtendedRegularExpressions() throws {
    try withScratchDirectory { scratch in
      _ = try setup(scratch)
      let result = try SiltaBinary.run(
        ["code", "grep", "portal", "portal|platform", "--json"], in: scratch)
      #expect(
        try envelope(result.stdout)["output"] as? String
          == "README.md:1:Acme platform\nportal/README.md:1:Acme portal\n")
      let invalid = try SiltaBinary.run(["code", "grep", "portal", "(", "--json"], in: scratch)
      #expect(invalid.termination == .exit(1))
      #expect(invalid.stdout.contains("Invalid extended regular expression."))
      let schema = try SiltaBinary.run(["schema", "code", "grep"], in: scratch)
      #expect(schema.stdout.contains("Extended regular expression"))
    }
  }

  @Test func longReadsAreCutWithAWarning() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let lines = (1...450).map { "match \($0)\n" }
      try Data(lines.joined().utf8).write(to: repo.appending(path: "apps/console/long.txt"))
      try commitAll(repo, scratch)
      let show = try SiltaBinary.run(
        ["code", "show", "console@HEAD", "long.txt", "--json"], in: scratch)
      #expect(try envelope(show.stdout)["output"] as? String == lines.prefix(400).joined())
      #expect(
        try warnings(show.stdout)["output_truncated"]
          == "Output cut after 400 of 450 lines; read the rest with --lines 401-450.")
      let full = try SiltaBinary.run(
        ["code", "show", "console@HEAD", "long.txt", "--lines", "1-450", "--json"], in: scratch)
      #expect(try envelope(full.stdout)["output"] as? String == lines.joined())
      #expect(try warnings(full.stdout).keys.sorted() == ["ref_stale"])
      let grep = try SiltaBinary.run(
        ["code", "grep", "console@HEAD", "match", "--json"], in: scratch)
      #expect(
        try envelope(grep.stdout)["output"] as? String
          == lines.prefix(200).enumerated().map { "long.txt:\($0.offset + 1):\($0.element)" }
          .joined())
      #expect(
        try warnings(grep.stdout)["output_truncated"]
          == "Output cut after 200 of 450 matching lines; "
          + "narrow it with a pathspec or a narrower pattern.")
    }
  }

  @Test func nonUTF8ContentIsDecodedLossily() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x0A]).write(
        to: repo.appending(path: "apps/console/latin1.txt"))
      try commitAll(repo, scratch)
      let show = try SiltaBinary.run(
        ["code", "show", "console@HEAD", "latin1.txt", "--json"], in: scratch)
      #expect(try envelope(show.stdout)["output"] as? String == "caf\u{FFFD} token\n")
      let grep = try SiltaBinary.run(
        ["code", "grep", "console@HEAD", "token", "--json"], in: scratch)
      #expect(
        try envelope(grep.stdout)["output"] as? String == "latin1.txt:1:caf\u{FFFD} token\n")
    }
  }

  @Test func attributesComeFromTheSelectedCommit() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try Data("Acme secret\n".utf8).write(to: repo.appending(path: "apps/console/secret.md"))
      try Data("secret.md binary\n".utf8).write(to: repo.appending(path: ".gitattributes"))
      try commitAll(repo, scratch)
      try Data("README.md binary\n".utf8).write(to: repo.appending(path: ".gitattributes"))
      let grep = try SiltaBinary.run(
        ["code", "grep", "console@HEAD", "Acme", "--json"], in: scratch)
      #expect(try envelope(grep.stdout)["output"] as? String == "README.md:1:Acme console\n")
    }
  }

  @Test func refsAreResolvedOrPointAtTheirRemote() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let sha = try git(["rev-parse", "origin/api"], repo, scratch).trimmingCharacters(
        in: .newlines)
      let pinned = try SiltaBinary.run(
        ["code", "show", "portal@" + sha, "api/README.md", "--json"], in: scratch)
      let data = try envelope(pinned.stdout)
      #expect(data["output"] as? String == "Acme API\n")
      #expect(data["ref"] as? String == sha)
      #expect(data["sha"] as? String == sha)
      let pinnedWarnings = try warnings(pinned.stdout)
      #expect(pinnedWarnings.isEmpty)
      let rejected = try SiltaBinary.run(
        ["code", "show", "portal@master@{999}", "README.md", "--json"], in: scratch)
      #expect(rejected.termination == .exit(2))
      #expect(rejected.stdout.contains("\"code\":\"not_found\""))
      try git(["update-ref", "-d", "refs/heads/portal-prod"], repo, scratch)
      let local = try SiltaBinary.run(
        ["code", "show", "portal@portal-prod", "portal/README.md", "--json"], in: scratch)
      #expect(local.termination == .exit(2))
      #expect(
        local.stdout.contains(
          "\"next\":[\"silta --ws 'acme' code show 'portal@origin/portal-prod' "
            + "'portal/README.md'\"]"
        ))
    }
  }

  @Test func pathsAreLiteralAndTheirKindIsNamed() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try FileManager.default.createDirectory(
        at: repo.appending(path: "apps/con*/docs"), withIntermediateDirectories: true)
      try Data("Acme doc\n".utf8).write(to: repo.appending(path: "apps/con*/docs/x.md"))
      try Data("Acme star\n".utf8).write(to: repo.appending(path: "apps/con*/README.md"))
      try Data("Acme colon\n".utf8).write(to: repo.appending(path: "apps/console/:colon.md"))
      try commitAll(repo, scratch)
      let starred = try SiltaBinary.run(
        ["code", "log", "portal", "*.md", "--json"], in: scratch)
      #expect(try envelope(starred.stdout)["output"] as? String == "")
      let show = try SiltaBinary.run(
        ["code", "show", "console@HEAD", ":colon.md", "--json"], in: scratch)
      #expect(try envelope(show.stdout)["output"] as? String == "Acme colon\n")
      let log = try SiltaBinary.run(
        ["code", "log", "console@HEAD", ":colon.md", "-n", "1", "--json"], in: scratch)
      #expect(try envelope(log.stdout)["output"] as? String != "")
      let grep = try SiltaBinary.run(
        ["code", "grep", "star@HEAD", "Acme", "--json"], in: scratch)
      #expect(
        try envelope(grep.stdout)["output"] as? String
          == "README.md:1:Acme star\ndocs/x.md:1:Acme doc\n")
      let docs = try SiltaBinary.run(
        ["--json", "code", "grep", "star@HEAD", "Acme", "--", "docs"], in: scratch)
      #expect(try envelope(docs.stdout)["output"] as? String == "docs/x.md:1:Acme doc\n")
      let listed = try SiltaBinary.run(["code", "ls", "portal", "--json"], in: scratch)
      #expect(try envelope(listed.stdout)["output"] as? String == "README.md\nportal/\n")
      let directory = try SiltaBinary.run(
        ["code", "show", "portal", "portal", "--json"], in: scratch)
      #expect(directory.termination == .exit(2))
      #expect(directory.stdout.contains("is a directory"))
      #expect(
        directory.stdout.contains("\"silta --ws 'acme' code ls 'portal@origin/portal' 'portal'\"")
      )
      let file = try SiltaBinary.run(
        ["code", "ls", "portal", "README.md", "--json"], in: scratch)
      #expect(file.termination == .exit(2))
      #expect(file.stdout.contains("is a file"))
      #expect(
        file.stdout.contains("\"silta --ws 'acme' code show 'portal@origin/portal' 'README.md'\"")
      )
      let missing = try SiltaBinary.run(
        ["code", "ls", "console@origin/portal", "--json"], in: scratch)
      #expect(missing.termination == .exit(2))
      #expect(missing.stdout.contains("App subpath \\\"apps/console\\\" not found"))
    }
  }

  @Test func lineSelectionsReportTheFileLength() throws {
    try withScratchDirectory { scratch in
      _ = try setup(scratch)
      let single = try SiltaBinary.run(
        ["code", "show", "portal", "portal/README.md", "--lines", "1", "--json"], in: scratch)
      #expect(try envelope(single.stdout)["output"] as? String == "Acme portal\n")
      let past = try SiltaBinary.run(
        ["code", "show", "portal", "portal/README.md", "--lines", "5-9", "--json"], in: scratch)
      #expect(try envelope(past.stdout)["output"] as? String == "")
      #expect(
        try warnings(past.stdout)["lines_past_eof"]
          == "\"portal/README.md\" has 1 line; --lines 5-9 goes past the end.")
      let help = try SiltaBinary.run(["code", "log", "--help"], in: scratch)
      #expect(help.stdout.contains("Positive commit limit (default 20).\n"))
    }
  }
}
