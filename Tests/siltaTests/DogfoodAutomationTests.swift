import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

/// The scripts that drive Codex and finish merged slices, run against fake `codex`,
/// `gh` and `silta` executables that record their calls.
@Suite(.timeLimit(.minutes(2)))
struct DogfoodAutomationTests {
  static let thread = "01a1a667-5c3b-7cb3-8760-7f29fd86a2a5"

  static func script(_ name: String) -> String {
    DogfoodReportTests.root.appending(path: "scripts/\(name)").path
  }

  static func git(_ arguments: [String], scratch: URL) throws -> String {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), ["-C", DogfoodReportTests.root.path] + arguments,
      in: scratch)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func run(
    _ script: String, _ arguments: [String], scratch: URL, environment: [String: String] = [:]
  ) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"), [Self.script(script)] + arguments, in: scratch,
      environment: ["PATH": scratch.appending(path: "tools").path + ":/usr/bin:/bin"]
        .merging(environment) { _, new in new })
  }

  static func fakeCodex(_ scratch: URL, exit status: Int32 = 0) throws {
    let calls = scratch.appending(path: "codex-calls")
    try DogfoodReportTests.tool(
      "codex",
      text: """
        #!/bin/bash
        printf '%s\\n' "$@" > \(shellWord(calls.path))-args
        env | sed 's/=.*//' | sort > \(shellWord(calls.path))-env
        cat > \(shellWord(calls.path))-stdin
        echo '{"type":"thread.started","thread_id":"\(thread)"}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"Acme plan first"}}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"Acme done"}}'
        exit \(status)

        """, in: scratch.appending(path: "tools"))
  }

  @Test func codexRunsAsCodexWithTheSandboxAndReportsItsThread() throws {
    try withScratchDirectory { scratch in
      try Self.fakeCodex(scratch, exit: 3)
      let log = scratch.appending(path: "run.jsonl")
      let result = try Self.run(
        "dogfood-codex.sh", ["start", DogfoodReportTests.root.path, log.path], scratch: scratch,
        environment: [
          "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "acme", "SILTA_ACTOR": "agent:claude:acme",
          "SILTA_SESSION": "acme", "CODEX_COMPANION_SESSION_ID": "acme",
        ])
      #expect(result.termination == .exit(3))
      #expect(result.stdout == "Thread: \(Self.thread)\nAcme done\n")
      let calls = scratch.appending(path: "codex-calls")
      let env = try String(contentsOf: URL(filePath: calls.path + "-env"), encoding: .utf8)
      for name in [
        "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "SILTA_ACTOR", "SILTA_SESSION",
        "CODEX_COMPANION_SESSION_ID",
      ] {
        #expect(!env.split(separator: "\n").contains(Substring(name)))
      }
      let args = try String(contentsOf: URL(filePath: calls.path + "-args"), encoding: .utf8)
        .split(separator: "\n").map(String.init)
      let home = scratch.appending(path: "home").path
      let common = try Self.git(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"], scratch: scratch)
      #expect(Array(args.prefix(2)) == ["exec", "--json"] && args.last == "-")
      #expect(
        args.contains("sandbox_workspace_write.writable_roots=[\"\(home)/.silta\",\"\(common)\"]"))
      #expect(args.contains("sandbox_workspace_write.network_access=true"))
      #expect(
        args.contains {
          $0.hasPrefix("shell_environment_policy.exclude=") && $0.contains("CLAUDE*")
        })
      let dir = args.firstIndex(of: "-C").map { args[$0 + 1] }
      #expect(dir == DogfoodReportTests.root.resolvingSymlinksInPath().path)
    }
  }

  @Test func codexResumesOnlyAnExactThread() throws {
    try withScratchDirectory { scratch in
      try Self.fakeCodex(scratch)
      let log = scratch.appending(path: "run.jsonl").path
      #expect(
        try Self.run("dogfood-codex.sh", ["resume", "--last", log], scratch: scratch).termination
          == .exit(1))
      #expect(
        try Self.run("dogfood-codex.sh", ["start", scratch.path, log], scratch: scratch)
          .termination == .exit(1))
      let result = try Self.run("dogfood-codex.sh", ["resume", Self.thread, log], scratch: scratch)
      #expect(result.termination == .exit(0) && result.stdout.hasPrefix("Thread: \(Self.thread)\n"))
      let args = try String(
        contentsOf: scratch.appending(path: "codex-calls-args"), encoding: .utf8
      ).split(separator: "\n").map(String.init)
      #expect(Array(args.prefix(4)) == ["exec", "resume", Self.thread, "--json"])
    }
  }

  static func fakeFinishTools(_ scratch: URL, state: String, body: String, sha: String) throws {
    let tools = scratch.appending(path: "tools")
    let pull = try JSONSerialization.data(withJSONObject: [
      "state": state, "mergeCommit": ["oid": sha], "body": body,
    ])
    try pull.write(to: scratch.appending(path: "pull.json"))
    let issue = "https://example.com/acme/issues/7"
    let task = try JSONSerialization.data(withJSONObject: [
      "ok": true,
      "data": [
        "ref": "SI-1", "status": "review",
        "links": [["rel": "cites", "target": "url:\(issue)"]],
      ],
    ])
    try task.write(to: scratch.appending(path: "task.json"))
    let log = shellWord(scratch.appending(path: "calls").path)
    try DogfoodReportTests.tool(
      "gh",
      text: """
        #!/bin/bash
        echo "gh $*" >> \(log)
        case "$1 $2" in
          'pr view') cat \(shellWord(scratch.appending(path: "pull.json").path)) ;;
          'issue view') echo OPEN ;;
          'issue comment') printf '%s\\n' "$5" > \(log)-comment ;;
          'issue close') ;;
          *) exit 98 ;;
        esac

        """, in: tools)
    try DogfoodReportTests.tool(
      "silta",
      text: """
        #!/bin/bash
        echo "silta $*" >> \(log)
        case "$3 $4" in
          'task show') cat \(shellWord(scratch.appending(path: "task.json").path)) ;;
          'task done') cat > \(log)-result; echo 'SI-1 done' ;;
          *) exit 98 ;;
        esac

        """, in: tools)
  }

  @Test func finishUsesTheMergeCommitAndTheDraftResult() throws {
    try withScratchDirectory { scratch in
      let sha = try Self.git(["rev-parse", "HEAD"], scratch: scratch)
      let body = """
        ## Summary\r
        Acme location.\r
        \r
        ## Draft result\r
        \r
        Implemented the Acme slice.\r
        Friction: none\r
        \r
        """
      try Self.fakeFinishTools(scratch, state: "MERGED", body: body, sha: sha)
      let result = try Self.run("dogfood-finish.sh", ["SI-1", "56"], scratch: scratch)
      #expect(
        result.termination == .exit(0) && result.stdout.contains("Next: scripts/install-dev.sh"))
      let calls = scratch.appending(path: "calls").path
      let expected =
        "Implemented the Acme slice.\nMerged in #56 (\(sha.prefix(7))).\nFriction: none\n"
      #expect(try String(contentsOf: URL(filePath: calls + "-result"), encoding: .utf8) == expected)
      let log = try String(contentsOf: URL(filePath: calls), encoding: .utf8)
      #expect(log.contains("silta --ws silta task done SI-1 --sha \(sha) -F -"))
      #expect(log.contains("gh issue close https://example.com/acme/issues/7"))
      let comment = try String(contentsOf: URL(filePath: calls + "-comment"), encoding: .utf8)
      #expect(comment.hasPrefix("Done in #56 (\(sha.prefix(7)))") && comment.hasSuffix(expected))
    }
  }

  @Test(arguments: [
    ("OPEN", "## Draft result\nDone.\nFriction: none\n"),
    ("MERGED", "## Draft result\nDone without friction.\n"),
    ("MERGED", "## Summary\nNo draft.\n"),
  ])
  func finishRefusesAnUnmergedPRAndAMissingFrictionLine(state: String, body: String) throws {
    try withScratchDirectory { scratch in
      try Self.fakeFinishTools(
        scratch, state: state, body: body,
        sha: try Self.git(["rev-parse", "HEAD"], scratch: scratch))
      let result = try Self.run("dogfood-finish.sh", ["SI-1", "56"], scratch: scratch)
      #expect(result.termination == .exit(1))
      let log = try String(contentsOf: scratch.appending(path: "calls"), encoding: .utf8)
      #expect(!log.contains("silta") && !log.contains("issue"))
    }
  }

  @Test func finishNeedsTheMergeCommitLocally() throws {
    try withScratchDirectory { scratch in
      try Self.fakeFinishTools(
        scratch, state: "MERGED", body: "## Draft result\nDone.\nFriction: none\n",
        sha: String(repeating: "a", count: 40))
      let result = try Self.run("dogfood-finish.sh", ["SI-1", "56"], scratch: scratch)
      #expect(result.termination == .exit(1) && result.stderr.contains("Next: git pull"))
    }
  }
}
