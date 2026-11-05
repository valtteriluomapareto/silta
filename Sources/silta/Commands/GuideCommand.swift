import ArgumentParser
import SiltaCore

/// The versioned, workspace-independent agent manual (spec §11).
struct GuideCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "guide", abstract: "Read the agent manual, or one topic.",
    discussion: "Topics: " + sections.map(\.topic).joined(separator: ", "))
  static let dataShape = Shape.object(["text": .string, "topics": .array(.string)])
  static let workspaceSource = WorkspaceSource.none
  @OptionGroup var global: GlobalOptions
  @Argument(help: "One topic from the list above; omitted prints the full manual.") var topic:
    String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let selected = Self.sections.filter { topic == nil || $0.topic == topic }
    guard !selected.isEmpty else {
      throw UsageError.invalid(
        message: "Unknown guide topic; see the topic list in help.", command: "silta guide")
    }
    let text = selected.map(\.text).joined(separator: "\n")
    return CommandOutput(
      text: text, quiet: text, data: Manual(text: text, topics: Self.sections.map(\.topic)))
  }

  private struct Manual: Encodable, Sendable {
    let text: String
    let topics: [String]
  }

  private struct Section: Sendable {
    let topic: String
    let text: String
  }

  private static let sections: [Section] = [
    Section(
      topic: "when",
      text: """
        # When to use Silta
        Use Silta for cross-repo work, another app or backend, branch-as-app repos, plans, \
        handoffs, review requests and meeting decisions. Trivial single-repo edits need no task. \
        Keep plans and results in Silta, never in PLAN.md or other repo plan files; never create \
        tracker items yourself.
        """ + "\n"),
    Section(
      topic: "start",
      text: """
        # Session start
        If the hook already printed a brief, do not run it again. Otherwise run `silta brief`. \
        Once you choose a task, run `silta brief --task AC-12`, then `silta task start AC-12`. \
        Text is the default; use --json only to parse output.
        For "work the backlog", run `silta task ls --status todo`, optionally with --app. Start \
        the first task; skip subtasks whose parent another session claims and skip claimed \
        tasks. Finish with a result before starting the next; continue until empty or the human \
        stops you.
        """ + "\n"),
    Section(
      topic: "recipes",
      text: """
        # Recipes
        Examples use the fictional Acme workspace and task AC-12. Replace names and paths with \
        refs from your brief; add --ws acme when outside that workspace.

        Read another app without checking out its branch:
        ```sh
        silta code grep platform-api -- 'Auth'
        silta code show platform-api -- 'src/Auth.swift'
        ```

        Use task add for a new task, task plan for a chosen task's checklist, and from-plan to \
        import an existing Markdown plan. Preview imports before writing; imports keep the \
        source unless --delete is explicitly approved when required.
        ```sh
        silta task add --start 'Implement Acme sign-in' --app platform-api
        silta task plan AC-12 -F - <<'PLAN'
        - [ ] Inspect the API
        - [ ] Implement and verify sign-in
        PLAN
        silta task plan AC-12 --step 1 --done
        silta task from-plan /tmp/acme-plan.md --dry-run
        silta task from-plan /tmp/acme-plan.md
        ```
        Use top-level checkboxes for numbered plan steps. A plan and a result go through stdin \
        with a quoted heredoc, so shell substitutions stay literal.

        Submit for review with `silta task submit AC-12`. Finish when the required review gate \
        is met; code tasks need their actual commit sha:
        ```sh
        silta task done AC-12 --sha <commit-sha> -F - <<'RESULT'
        What was done: implemented and verified Acme sign-in.
        Decisions: reused the existing authentication API.
        What's left: nothing.
        RESULT
        ```
        """ + "\n"),
    Section(
      topic: "human",
      text: """
        # Working for the human
        The human talks to you; you run Silta. Decide and record routine choices with `silta \
        comment AC-12 --kind decision -m 'Reuse the existing authentication API.'`, then carry \
        on.
        Ask about scope changes, a new dependency, a public API/schema/migration, anything \
        another app or the customer sees, deleting what you did not create, anything \
        irreversible, and money. The planned ask_about: short setting asks only about the last \
        four; this version does not yet support that setting.
        Put all approvals, proposals to triage and questions in one message. For human-only \
        commands, name the exact commands, wait for yes, then run only those commands with \
        --approved "<their words>". Never invent approval words.
        Usually propose nothing; never more than two proposals per session, only ideas you would \
        bet the human wants. `task add --start` is only for work the human requested. If asked \
        to add work for later, use their words with --approved so it becomes todo without \
        triage.
        If brief shows proposals: ask, do not propose: name each idea and its exact `silta task \
        add` command in your message, then add only the approved ideas with --approved. Without \
        a human, list ideas under "What's left" in a handoff/result, never in a question, TODO \
        comment or file.
        When no answer can come, leave pending commands in a handoff and pick other work; do not \
        wait. Persistent questions to @me and `silta inbox --for me` are not available in this \
        version. Until they ship, relay known pending choices in one short message.
        """ + "\n"),
    Section(
      topic: "questions",
      text: """
        # Questions
        Ask in chat. Record a question only when blocked beyond this session; until question \
        comments ship, record the pending question and exact commands in your handoff.
        """ + "\n"),
    Section(
      topic: "blocked",
      text: """
        # Blocked
        A question to the human does not block a task. Ask in chat if the human can answer, \
        including questions about the customer. If only an external party (ext:acme) or another \
        task can unblock you, keep doing useful work; block only when none remains.
        ```sh
        silta task block AC-12 --on ext:acme -m 'Need the identity provider callback URL.'
        ```
        Silta sends nothing: tell the human exactly what to ask whom, leave a handoff and pick \
        other work. Never unblock with open blockers without the human's approval, and never put \
        "waiting for" into repo files or plans.
        """ + "\n"),
    Section(
      topic: "handoff",
      text: """
        # Handoff
        Always leave a handoff before stopping. It releases your claim while preserving status. \
        Use the actual branch and sha; the next session reads the task and starts it again.
        ```sh
        silta comment AC-12 --kind handoff -F - <<'HANDOFF'
        State: API inspected; implementation remains.
        Next step: implement sign-in and run the verification checks.
        Open questions: none.
        Branch and sha: feature/acme-sign-in at <commit-sha>.
        HANDOFF
        silta task show AC-12
        silta task start AC-12
        ```
        """ + "\n"),
    Section(
      topic: "reviews",
      text: """
        # Reviews
        Use `silta task submit AC-12` to request review. Read discussion with `silta task show \
        AC-12`. Record what changed and the proving test with `silta comment AC-12 -m 'Changed \
        the validation; SignInTests proves it.'`. Threaded replies are not available in this \
        version. Do not resolve review threads yourself unless assigned that responsibility.
        The M2 inbox take, task diff and task review workflow is not available in this version.
        """ + "\n"),
    Section(
      topic: "refusals",
      text: """
        # Refusals
        Read the error's code, next_by and next commands. A command's next_by can override the \
        code default. Never use --force, --steal, where --set, promote or --allow-secret on your \
        own initiative; name the command and obtain the human's words with --approved first. \
        Never create tracker items or repo plan files.
        """ + "\n"
          + ErrorCode.allCases.map { "\($0.rawValue) (exit \($0.exitCode)): \($0.agentShould)\n" }
          .joined()),
    Section(
      topic: "output",
      text: """
        # Output
        Text is the default; --quiet preserves read output. Use --json only when parsing; it \
        prints the schema-1 envelope on stdout. Errors carry actionable next commands. Use \
        `silta schema` for command shapes and `silta help refs` for the reference grammar.
        Topics: when, start, recipes, human, questions, blocked, handoff, reviews, refusals, \
        output. Read one with `silta guide <topic>`.
        """ + "\n"),
  ]
}
