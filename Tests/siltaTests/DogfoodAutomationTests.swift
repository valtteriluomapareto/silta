import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

/// The scripts that drive Codex and finish merged slices, run against fake `codex`,
/// `gh` and `silta` executables that record their calls.
@Suite(.timeLimit(.minutes(2)))
struct DogfoodAutomationTests {
  static let thread = "01a1a667-5c3b-7cb3-8760-7f29fd86a2a5"
  static let started = "{\"type\":\"thread.started\",\"thread_id\":\"\(thread)\"}"

  static func message(_ text: String) -> String {
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(text)\"}}"
  }

  static func git(_ arguments: [String], in directory: URL, scratch: URL) throws -> String {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"),
      ["-c", "user.name=Acme", "-c", "user.email=acme@example.com", "-C", directory.path]
        + arguments, in: scratch)
    #expect(result.termination == .exit(0), "git \(arguments): \(result.stderr)")
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func run(
    _ script: URL, _ arguments: [String], scratch: URL, environment: [String: String] = [:]
  ) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"), [script.path] + arguments, in: scratch,
      environment: ["PATH": scratch.appending(path: "tools").path + ":/usr/bin:/bin"]
        .merging(environment) { _, new in new })
  }

  /// A scratch repository holding a copy of the Codex script, and a linked worktree of it.
  struct CodexRepository {
    let script: URL
    let repo: URL
    let worktree: URL
  }

  static func codexRepository(_ scratch: URL) throws -> CodexRepository {
    let repo = scratch.appending(path: "acme", directoryHint: .isDirectory)
    let worktree = scratch.appending(path: "acme-codex", directoryHint: .isDirectory)
    let script = repo.appending(path: "scripts/dogfood-codex.sh")
    try FileManager.default.createDirectory(
      at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: DogfoodReportTests.root.appending(path: "scripts/dogfood-codex.sh"), to: script)
    _ = try git(["init", "-q", "-b", "main"], in: repo, scratch: scratch)
    _ = try git(["add", "."], in: repo, scratch: scratch)
    _ = try git(["commit", "-q", "-m", "Acme"], in: repo, scratch: scratch)
    _ = try git(["worktree", "add", "-q", "--detach", worktree.path], in: repo, scratch: scratch)
    return CodexRepository(script: script, repo: repo, worktree: worktree)
  }

  static func fakeCodex(
    _ scratch: URL, output: [String], exit status: Int32 = 0, setting: String? = nil,
    then extra: String = ""
  ) throws {
    let calls = shellWord(scratch.appending(path: "codex-calls").path)
    var lines = output.map { "printf '%s\\n' " + shellWord($0) }.joined(separator: "\n")
    if let setting {
      lines +=
        "\ngit config --file \"$(git rev-parse --absolute-git-dir)/config.worktree\" "
        + setting
    }
    try DogfoodReportTests.tool(
      "codex",
      text: """
        #!/bin/bash
        printf '%s\\n' "$@" > \(calls)-args
        env | sed 's/=.*//' | sort > \(calls)-env
        pwd -P > \(calls)-pwd
        cat > \(calls)-stdin
        \(lines)
        \(extra)
        exit \(status)

        """, in: scratch.appending(path: "tools"))
  }

  static func calls(_ scratch: URL, _ name: String) throws -> [String] {
    try String(contentsOf: scratch.appending(path: "codex-calls-\(name)"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  /// A command that leaves `marker` in the worktree's git dir, as an interrupted git
  /// operation would. A trailing slash makes it a directory.
  static func leaving(_ marker: String) -> String {
    let path = "\"$(git rev-parse --absolute-git-dir)/\(marker)\""
    return marker.hasSuffix("/") ? "mkdir -p \(path)" : "touch \(path)"
  }

  static let callerMarkers = [
    "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "SILTA_ACTOR", "SILTA_SESSION",
    "CODEX_COMPANION_SESSION_ID",
  ]

  @Test(arguments: [false, true])
  func codexRunsAsCodexInItsWorktreeWithTheSandbox(resume: Bool) throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      let (script, repo, worktree) = (fixture.script, fixture.repo, fixture.worktree)
      try Self.fakeCodex(
        scratch, output: [Self.started, Self.message("Acme plan"), Self.message("Acme done")],
        exit: 3)
      let log = scratch.appending(path: "run.jsonl").path
      let arguments =
        resume ? ["resume", worktree.path, Self.thread, log] : ["start", worktree.path, log]
      let result = try Self.run(
        script, arguments, scratch: scratch,
        environment: Dictionary(uniqueKeysWithValues: Self.callerMarkers.map { ($0, "acme") }))
      #expect(result.termination == .exit(3))
      #expect(result.stdout == "Thread: \(Self.thread)\nAcme done\n")
      let env = try Self.calls(scratch, "env")
      #expect(Self.callerMarkers.allSatisfy { !env.contains($0) })
      let dir = try Self.git(["rev-parse", "--show-toplevel"], in: worktree, scratch: scratch)
      #expect(try Self.calls(scratch, "pwd") == [dir])
      let args = try Self.calls(scratch, "args")
      #expect(
        Array(args.prefix(resume ? 4 : 2))
          == (resume ? ["exec", "resume", Self.thread, "--json"] : ["exec", "--json"]))
      #expect(args.last == "-" && args.contains("-C") == !resume)
      let common = try Self.git(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo, scratch: scratch)
      let gitdir = try Self.git(
        ["rev-parse", "--absolute-git-dir"], in: worktree, scratch: scratch)
      let siltaHome = scratch.appending(path: "silta-home").path
      let roots =
        "sandbox_workspace_write.writable_roots=[\"\(siltaHome)\",\"\(common)/objects\","
        + "\"\(common)/refs\",\"\(common)/logs\",\"\(gitdir)\"]"
      #expect(args.contains(roots))
      #expect(args.contains("approval_policy=\"never\""))
      #expect(args.contains("model=\"gpt-6.1-sol\""))
      #expect(args.contains("model_reasoning_effort=\"high\""))
      #expect(args.contains("sandbox_workspace_write.network_access=true"))
      #expect(args.contains("shell_environment_policy.set.SILTA_ACTOR=\"agent:codex\""))
      #expect(
        args.contains {
          $0.hasPrefix("shell_environment_policy.exclude=") && $0.contains("CLAUDE*")
        })
    }
  }

  @Test func codexRunsAFireworksModelInTheSameSandbox() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      try Self.fakeCodex(scratch, output: [Self.started, Self.message("Acme done")])
      let log = scratch.appending(path: "run.jsonl").path
      let model = "accounts/fireworks/models/acme-flash"
      for (environment, status) in [
        (["DOGFOOD_MODEL": "fireworks:\(model)"], 1 as Int32),
        (["DOGFOOD_MODEL": "acme:\(model)", "FIREWORKS_API_KEY": "acme-key"], 1),
        (["DOGFOOD_MODEL": "fireworks:\(model)", "FIREWORKS_API_KEY": "acme-key"], 0),
      ] {
        let result = try Self.run(
          fixture.script, ["start", fixture.worktree.path, log], scratch: scratch,
          environment: environment)
        #expect(result.termination == .exit(status), "\(environment)")
      }
      let args = try Self.calls(scratch, "args")
      #expect(args.contains("model=\"\(model)\"") && !args.contains("model=\"gpt-6.1-sol\""))
      #expect(args.contains("model_provider=\"fireworks\""))
      #expect(
        args.contains {
          $0.hasPrefix("model_providers.fireworks=") && $0.contains("FIREWORKS_API_KEY")
        })
      #expect(args.contains("model_reasoning_effort=\"high\""))
      #expect(
        args.contains {
          $0.hasPrefix("shell_environment_policy.exclude=") && $0.contains("FIREWORKS_API_KEY")
        })
      #expect(try Self.calls(scratch, "env").contains("FIREWORKS_API_KEY"))
    }
  }

  @Test func codexRefusesTheMainCheckoutAndInexactThreads() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      let (script, repo, worktree) = (fixture.script, fixture.repo, fixture.worktree)
      try Self.fakeCodex(scratch, output: [Self.started])
      let log = scratch.appending(path: "run.jsonl").path
      for arguments in [
        ["start", repo.path, log], ["start", scratch.path, log],
        ["resume", worktree.path, "--last", log],
        ["resume", worktree.path, String(repeating: "-", count: 36), log],
        ["resume", Self.thread, log],
      ] {
        let result = try Self.run(script, arguments, scratch: scratch)
        #expect(result.termination == .exit(1), "\(arguments)")
      }
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "codex-calls-args").path))
    }
  }

  @Test func codexOutputSurvivesUnreadableLinesAndAMissingThreadEvent() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      let (script, worktree) = (fixture.script, fixture.worktree)
      try Self.fakeCodex(
        scratch, output: ["warning: not JSON", Self.message("Acme done"), "{\"type\":"], exit: 2)
      let log = scratch.appending(path: "run.jsonl").path
      let resumed = try Self.run(
        script, ["resume", worktree.path, Self.thread, log], scratch: scratch)
      #expect(resumed.termination == .exit(2))
      #expect(resumed.stdout == "Thread: \(Self.thread)\nAcme done\n")
      try Self.fakeCodex(scratch, output: [], exit: 1)
      let started = try Self.run(script, ["start", worktree.path, log], scratch: scratch)
      #expect(started.termination == .exit(1) && started.stdout == "Thread: unknown\n")
    }
  }

  @Test(arguments: [
    ("CHERRY_PICK_HEAD", "cherry-pick (CHERRY_PICK_HEAD)", "cherry-pick --quit"),
    ("rebase-merge/", "rebase (rebase-merge)", "rebase --quit"),
  ])
  func codexWarnsAboutUnfinishedGitState(marker: String, state: String, action: String) throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      try Self.fakeCodex(
        scratch, output: [Self.started, Self.message("Acme done")], exit: 4,
        then: Self.leaving(marker))
      let log = scratch.appending(path: "run.jsonl").path
      let result = try Self.run(
        fixture.script, ["start", fixture.worktree.path, log], scratch: scratch)
      let dir = try Self.git(
        ["rev-parse", "--show-toplevel"], in: fixture.worktree, scratch: scratch)
      withKnownIssue {
        #expect(result.stderr.contains(state))
        #expect(result.stderr.contains("git -C \(dir) \(action)"))
        #expect(result.stderr.contains("cannot clear"))
      }
      #expect(result.termination == .exit(4))
      #expect(result.stdout == "Thread: \(Self.thread)\nAcme done\n")
    }
  }

  @Test func codexSaysNothingWhenNoGitOperationIsUnfinished() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      try Self.fakeCodex(scratch, output: [Self.started, Self.message("Acme done")])
      let log = scratch.appending(path: "run.jsonl").path
      let result = try Self.run(
        fixture.script, ["start", fixture.worktree.path, log], scratch: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
    }
  }
}

extension DogfoodAutomationTests {
  @Test(arguments: [
    ("codex.localEnvironmentConfigPath __none__", 0 as Int32),
    ("core.fsmonitor 'touch acme-pwned'", 70),
    ("include.path /tmp/acme.config", 70),
  ])
  func codexStopsWhenItChangesTheWorktreesGitSetup(setting: String, status: Int32) throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      try Self.fakeCodex(
        scratch, output: [Self.started, Self.message("Acme done")], setting: setting)
      let log = scratch.appending(path: "run.jsonl").path
      let result = try Self.run(
        fixture.script, ["start", fixture.worktree.path, log], scratch: scratch)
      #expect(result.termination == .exit(status))
      #expect(result.stdout.hasPrefix("Thread: \(Self.thread)\n"))
      #expect(result.stderr.contains("don't run git") == (status == 70))
    }
  }

  @Test func codexSkipsTheWarningWhenTheGitSetupCheckRefused() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      try Self.fakeCodex(
        scratch, output: [Self.started, Self.message("Acme done")],
        setting: "core.fsmonitor 'touch acme-pwned'", then: Self.leaving("CHERRY_PICK_HEAD"))
      let log = scratch.appending(path: "run.jsonl").path
      let result = try Self.run(
        fixture.script, ["start", fixture.worktree.path, log], scratch: scratch)
      #expect(result.termination == .exit(70))
      #expect(result.stderr.contains("don't run git") && !result.stderr.contains("--quit"))
    }
  }
}

extension DogfoodAutomationTests {
  @Test func codexFinishesWhenTheScriptChangesDuringTheRun() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.codexRepository(scratch)
      let path = shellWord(fixture.script.path)
      // An edit in place while Codex runs shifts the bytes bash has yet to read.
      try Self.fakeCodex(
        scratch, output: [Self.started, Self.message("Acme done")],
        then: "body=\"$(cat \(path))\"; printf '# an edit that shifts every line\\n%s\\n' "
          + "\"$body\" > \(path)")
      let log = scratch.appending(path: "run.jsonl").path
      let result = try Self.run(
        fixture.script, ["start", fixture.worktree.path, log], scratch: scratch)
      #expect(
        result.termination == .exit(0) && result.stdout == "Thread: \(Self.thread)\nAcme done\n")
    }
  }
}

extension DogfoodAutomationTests {
  static let issue = "https://example.com/acme/issues/7"

  static func finish(_ scratch: URL) throws -> CLIResult {
    try run(
      DogfoodReportTests.root.appending(path: "scripts/dogfood-finish.sh"), ["SI-1", "56"],
      scratch: scratch)
  }

  static func head(_ scratch: URL) throws -> String {
    try git(["rev-parse", "HEAD"], in: DogfoodReportTests.root, scratch: scratch)
  }

  static func fakeFinishTools(
    _ scratch: URL, state: String = "MERGED", body: String, sha: String,
    status: String = "review", linked: Bool = true, issueState: String = "OPEN",
    app: String? = "silta"
  ) throws {
    let tools = scratch.appending(path: "tools")
    let pull = try JSONSerialization.data(withJSONObject: [
      "state": state, "mergeCommit": ["oid": sha], "body": body,
    ])
    try pull.write(to: scratch.appending(path: "pull.json"))
    let links: [[String: String]] = linked ? [["rel": "cites", "target": "url:\(issue)"]] : []
    let task = try JSONSerialization.data(withJSONObject: [
      "ok": true,
      "data": ["ref": "SI-1", "status": status, "links": links, "app": app as Any].compactMapValues
      {
        $0 is NSNull ? nil : $0
      },
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
          'issue view') echo \(issueState) ;;
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
          'task show') [[ -f \(shellWord(scratch.appending(path: "silta-fails").path)) ]] \\
            && { echo '{"ok":false,"error":{"code":"not_found"}}'; exit 2; }
            cat \(shellWord(scratch.appending(path: "task.json").path)) ;;
          'task done') cat > \(log)-result; echo 'SI-1 done' ;;
          *) exit 98 ;;
        esac

        """, in: tools)
  }

  static func log(_ scratch: URL, _ suffix: String = "") throws -> String {
    let file = scratch.appending(path: "calls" + suffix)
    guard FileManager.default.fileExists(atPath: file.path) else { return "" }
    return try String(contentsOf: file, encoding: .utf8)
  }

  @Test(arguments: [
    (
      "## Summary\r\nAcme.\r\n\r\n## Draft result\r\n\r\nImplemented Acme.\r\nFriction: none\r\n",
      "Implemented Acme.\n"
    ),
    (
      "## Draft Result\nImplemented Acme.\n\nFriction: none\n\n🤖 Generated with Acme\n",
      "Implemented Acme.\n"
    ),
    (
      "## Draft result\nImplemented Acme.\nFriction: none\n## Notes\nNot part.\n",
      "Implemented Acme.\n"
    ),
    ("## Draft result\nFriction: none\n", ""),
  ])
  func finishUsesTheMergeCommitAndTheDraftResult(body: String, text: String) throws {
    try withScratchDirectory { scratch in
      let sha = try Self.head(scratch)
      try Self.fakeFinishTools(scratch, body: body, sha: sha)
      let result = try Self.finish(scratch)
      #expect(
        result.termination == .exit(0) && result.stdout.contains("Next: scripts/install-dev.sh"))
      let expected = text + "Merged in #56 (\(sha.prefix(7))).\nFriction: none\n"
      #expect(try Self.log(scratch, "-result") == expected)
      let log = try Self.log(scratch)
      #expect(log.contains("silta --ws silta task done SI-1 --sha \(sha) -F -"))
      #expect(log.contains("gh issue close \(Self.issue)"))
      let comment = try Self.log(scratch, "-comment")
      #expect(comment.hasPrefix("Done in #56 (\(sha.prefix(7)))") && comment.hasSuffix(expected))
    }
  }

  @Test func finishCompletesAnAppLessTaskWithoutASha() throws {
    try withScratchDirectory { scratch in
      let sha = try Self.head(scratch)
      try Self.fakeFinishTools(
        scratch, body: "## Draft result\nDone.\nFriction: none\n", sha: sha, app: nil)
      let result = try Self.finish(scratch)
      #expect(result.termination == .exit(0))
      let calls = try Self.log(scratch)
      #expect(calls.contains("silta --ws silta task done SI-1 -F -") && !calls.contains("--sha"))
      #expect(try Self.log(scratch, "-result").contains("Merged in #56 (\(sha.prefix(7)))."))
    }
  }

  @Test(arguments: [
    ("OPEN", "## Draft result\nDone.\nFriction: none\n", "is not merged"),
    ("MERGED", "## Draft result\nDone without friction.\n", "no Friction: line"),
    ("MERGED", "## Summary\nNo draft.\nFriction: none\n", "no \"## Draft result\" section"),
  ])
  func finishRefusesAnUnmergedPRAndAMissingDraft(state: String, body: String, reason: String)
    throws
  {
    try withScratchDirectory { scratch in
      try Self.fakeFinishTools(scratch, state: state, body: body, sha: try Self.head(scratch))
      let result = try Self.finish(scratch)
      #expect(result.termination == .exit(1) && result.stderr.contains(reason))
      let calls = try Self.log(scratch)
      #expect(!calls.contains("silta") && !calls.contains("issue"))
    }
  }

  @Test func finishNeedsTheMergeCommitLocally() throws {
    try withScratchDirectory { scratch in
      try Self.fakeFinishTools(
        scratch, body: "## Draft result\nDone.\nFriction: none\n",
        sha: String(repeating: "a", count: 40))
      let result = try Self.finish(scratch)
      #expect(result.termination == .exit(1) && result.stderr.contains("Next: git pull"))
      let calls = try Self.log(scratch)
      #expect(!calls.contains("silta"))
    }
  }

  @Test(arguments: ["doing", "todo", "blocked"])
  func finishOnlyCompletesASubmittedTask(status: String) throws {
    try withScratchDirectory { scratch in
      try Self.fakeFinishTools(
        scratch, body: "## Draft result\nDone.\nFriction: none\n", sha: try Self.head(scratch),
        status: status)
      let result = try Self.finish(scratch)
      #expect(result.termination == .exit(1) && result.stderr.contains("not review"))
      let calls = try Self.log(scratch)
      #expect(!calls.contains("task done"))
    }
  }

  @Test func finishRerunsSkipWhatIsAlreadyDone() throws {
    try withScratchDirectory { scratch in
      let body = "## Draft result\nDone.\nFriction: none\n"
      try Self.fakeFinishTools(
        scratch, body: body, sha: try Self.head(scratch), status: "done", issueState: "CLOSED")
      let closed = try Self.finish(scratch)
      #expect(closed.termination == .exit(0) && closed.stdout.contains("already done"))
      #expect(closed.stdout.contains("already closed"))
      let calls = try Self.log(scratch)
      #expect(!calls.contains("task done") && !calls.contains("issue close"))
      try Self.fakeFinishTools(
        scratch, body: body, sha: try Self.head(scratch), status: "done", linked: false)
      let unlinked = try Self.finish(scratch)
      #expect(unlinked.termination == .exit(0) && unlinked.stdout.contains("links no GitHub issue"))
    }
  }

  @Test func finishReportsASiltaFailure() throws {
    try withScratchDirectory { scratch in
      try Self.fakeFinishTools(
        scratch, body: "## Draft result\nDone.\nFriction: none\n", sha: try Self.head(scratch))
      FileManager.default.createFile(
        atPath: scratch.appending(path: "silta-fails").path, contents: nil)
      let result = try Self.finish(scratch)
      #expect(result.termination == .exit(1) && result.stderr.contains("not_found"))
      let calls = try Self.log(scratch)
      #expect(!calls.contains("task done") && !calls.contains("issue"))
    }
  }
}
