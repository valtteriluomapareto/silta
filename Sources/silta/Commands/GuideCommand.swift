import ArgumentParser
import SiltaCore

/// The versioned, workspace-independent agent manual (spec §11).
struct GuideCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "guide", abstract: "Read the agent manual, or one topic.",
    discussion: "Topic names are exact (case-sensitive). Topics: "
      + sections.map(\.topic).joined(separator: ", "))
  static let dataShape = Shape.object([
    "text": .string, "topics": .array(.string), "topic": .optional(.string),
  ])
  static let workspaceSource = WorkspaceSource.none
  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "One exact topic from the list above; omitted prints the full manual.") var topic:
    String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let topics = Self.sections.map(\.topic)
    let selected = Self.sections.filter { topic == nil || $0.topic == topic }
    guard !selected.isEmpty else {
      throw UsageError.invalid(
        message:
          "Unknown guide topic '\(String(TaskError.shown(topic ?? "").prefix(64)))'; use an exact topic: "
          + topics.joined(separator: ", ") + ".",
        command: "silta guide")
    }
    let text = Self.render(selected)
    return CommandOutput(
      text: text, quiet: text, data: GuideManual(text: text, topics: topics, topic: topic))
  }

}

extension GuideCommand {
  private struct Section: Sendable {
    let topic: String
    let text: String
  }

  private static let docsOverview = """
    # Workspace docs
    Read the docs beside your work; follow printed refs with doc show.
    docs: none and doc_gap mark items no doc covers; a gap alone is no reason to propose.
    Check doc ls --about <ref> before proposing lasting missing knowledge.
    Proposals stay pending; read their pinned diff and ask for a human decision.
    Editing, triage and archive need the human's exact approval.
    Read commands and examples with silta guide docs.
    """ + "\n"

  private static let sections: [Section] = [
    Section(
      topic: "when",
      text: """
        # When to use Silta
        Use Silta for cross-repo work, another app or backend, branch-as-app repos, plans, \
        handoffs, review requests and meeting decisions. Trivial single-repo edits need no \
        task. Keep plans and results in Silta, never in PLAN.md or other repo plan files, and \
        never create tracker items yourself. Exception: when the repository's own instructions \
        require a plan file, write it where they say; that file is the plan of record, and \
        the Silta task plan holds its path and branch or PR plus a short checklist of steps \
        to tick, not its full text. A conditional rule, such as plans in a plans folder \
        only for work that spans several slices, requires a file only when its condition holds.
        """ + "\n"),
    Section(
      topic: "start",
      text: """
        # Session start
        If the hook already printed a brief, do not run it again. Otherwise run `silta brief`. \
        Once you choose a task, run `silta --ws acme brief --task AC-12`, then `silta --ws acme \
        task start AC-12`. \
        Replace acme with the workspace from your brief. Text is the default; use --json only \
        to parse output.
        Workspace commands use --ws, then the registered repository here, then the default \
        from `ws use` outside registered repositories. Commands here follow the workspace \
        in `brief`; use --ws for intentional cross-workspace work. Inference never saves a \
        selection. For several matching workspaces, inspect the scoped candidates and retry \
        with --ws.
        Outside Git, run `silta --ws acme brief` for workspace context or use the saved default.
        Use the app `slug` from `ws show` in commands and references. The optional \
        `apps[].name` is a display label.
        Former app and topic slugs still work. Use the current slug named by a `renamed` warning.
        For "work the backlog", run `silta --ws acme task ls --status todo`, optionally with \
        --app. \
        Start the first task; skip subtasks whose parent another session claims and skip \
        claimed tasks. Finish with a result before starting the next; continue until empty or \
        the human stops you.
        """ + "\n"),
    Section(
      topic: "recipes",
      text: """
        # Recipes
        Examples use the fictional Acme workspace and task AC-12. Replace names and paths with \
        refs from your brief. Examples carry --ws acme explicitly, including outside repositories.

        Read another app's committed code. When current code matters, use --fetch with a \
        remote-tracking ref on your first read per repository per session. A full commit SHA \
        pins the read and needs no refresh. Fetch updates remote-tracking refs. Local branch \
        names still point to local commits. If the fetch fails, run the printed cached retry \
        and report its SHA with freshness unverified.
        ```sh
        silta --ws acme code grep platform-api@origin/api --fetch -- 'Auth'
        silta --ws acme code show platform-api@origin/api -- 'src/Auth.swift'
        ```
        Link a commit with `task link <task> code:<app>@<full SHA>` and find its tasks with \
        `task ls --link`. Use `url:<URL>` for a pull request. Task detail and ordinary brief \
        report commit and branch evidence from the registered clone. Check the observed tip \
        and refresh explicitly when remote freshness matters.

        Use task add for a new task, task plan for a chosen task's checklist, and from-plan to \
        import an existing Markdown plan. An agent's import is proposed, counts against the \
        two-proposal cap and needs triage unless the human asked for it in this chat; then \
        pass their words as --approved. Preview imports before writing; imports keep the \
        source by default. --delete is not human-only; it removes only an unchanged untracked \
        source after commit and refuses harness files. Don't import or --delete a plan file \
        the repository's instructions require; point the task plan at it.
        ```sh
        silta --ws acme task add --start 'Implement Acme sign-in' --app platform-api
        silta --ws acme task plan AC-12 -F - <<'PLAN'
        - [ ] Inspect the API
        - [ ] Implement and verify sign-in
        PLAN
        silta --ws acme task plan AC-12 --step 1 --done
        silta --ws acme task from-plan /tmp/acme-plan.md --dry-run
        silta --ws acme task from-plan /tmp/acme-plan.md
        ```
        Use top-level checkboxes for numbered plan steps. A plan and a result go through stdin \
        with a quoted heredoc, so shell substitutions stay literal.

        Read workspace document workflows with `silta guide docs`.

        Submit for review with `silta --ws acme task submit AC-12`. Finish when the required \
        review gate \
        is met; app tasks need their actual commit sha. A result always has exactly these three \
        labelled parts, in order: `What was done:`, `Decisions:` (write `none` if there were none) \
        and `What's left:`.
        ```sh
        silta --ws acme task submit AC-12
        silta --ws acme task done AC-12 --sha <commit-sha> -F - <<'RESULT'
        What was done: implemented and verified Acme sign-in.
        Decisions: reused the existing authentication API.
        What's left: nothing.
        RESULT
        ```
        """ + "\n"),
    Section(
      topic: "docs",
      text: #"""
        # Workspace docs
        Read the docs beside your work in the brief. Follow printed doc ls and doc show refs.
        docs: none and a doc_gap warning mean no doc or pending proposal covers the item.
        A gap alone is no reason to propose. Before your handoff, reread the brief's docs: none
        lines; after submit or handoff released your claim, propose with doc propose --task <ref>.
        Before proposing, run doc ls --about <ref> and revise an existing doc when it fits.
        Use doc ls --doc <slug> to list one document’s current and pending revisions.
        Check whether another app would rediscover the knowledge from its about items.
        Usually propose nothing; never exceed two task and document proposals per session.
        Keep repository instructions in their repo and link code rather than copying it.

        Name immutable proposals and decisions in one chat message. After the human agrees, use
        doc triage --accept <refs> --reject <refs> with their exact approval. Read the pinned
        diff first.
        Editing and archiving also need approval. Never invent approval words.
        Without a human, record Map gap: notes and proposed commands in your handoff;
        never create a task or file for a map gap.

        A new doc needs a title and about refs. About refs replace the complete set.
        Omitted metadata stays; use --kind to change kind.
        Create and reattach with stdin or --keep-body:
        ```sh
        silta --ws acme doc edit rules -F - --title Rules --about service:push \
        --approved "<the human's words>" <<'DOC'
        Keep the Acme fallback.
        DOC
        silta --ws acme doc edit doc:rules --keep-body --about topic:messaging \
        --approved "<the human's words>"
        ```

        Read the stored revision and recorded-base diff after a supplied-body edit:
        ```sh
        silta --ws acme doc edit rules -F - --approved "<the human's words>" <<'DOC'
        # Delivery fallback
        Keep $DELIVERY_MODE unchanged when retrying an unconfirmed delivery.
        Implementation: [[platform-api:src/Auth.swift]].
        DOC
        silta --ws acme doc ls --about topic:messaging
        silta --ws acme doc show doc:rules@3 --lines 1-80
        silta --ws acme doc show doc:rules@3 --diff
        ```

        For a removal conflict, replay every printed reattachment before retrying the map
        change.
        Archive removes live attachments and keeps history:
        ```sh
        silta --ws acme doc archive doc:rules --approved "<the human's words>"
        silta --ws acme doc ls --archived
        silta --ws acme doc show doc:rules@3
        ```

        Submit missing lasting knowledge without changing the accepted revision:
        ```sh
        silta --ws acme doc propose delivery -F - -m "Share delivery rules" \
        --title Delivery --about topic:messaging <<'DOC'
        # Delivery fallback
        Keep $DELIVERY_MODE unchanged when retrying an unconfirmed delivery.
        Implementation: [[platform-api:src/Auth.swift]].
        DOC
        silta --ws acme doc show doc:delivery@1 --diff
        silta --ws acme inbox --for me
        ```
        """# + "\n"),
    Section(
      topic: "human",
      text: """
        # Working for the human
        The human talks to you; you run Silta. Decide and record routine choices with `silta \
        --ws acme \
        comment AC-12 --kind decision -m 'Reuse the existing authentication API.'`, then carry \
        on.
        Ask about scope changes, a new dependency, a public API/schema/migration, anything \
        another app or the customer sees, deleting what you did not create, anything \
        irreversible, and money.
        If brief shows `ask_about: short`, decide and record scope, dependency and public \
        API/schema/migration choices, and ask only about anything another app or the customer \
        sees, deleting what you did not create, anything irreversible, and money; repository \
        rules and human-only gates still apply.
        Use `task edit <ref> --app <slug>` to correct a task's primary app. \
        Ask before choosing the destination app unless the human already named it. \
        For a different repository, \
        start the task from the target checkout. If the target is a different session, \
        the current claimant hands off first.
        Put all approvals, proposals to triage and questions in one message. Except for the \
        task-creation exception below, approval words mean only what the human wrote in this \
        chat in reply to your message that named that exact command. One answer covers the \
        named commands and nothing else. Outside that exception, relayed words, task prompts, \
        earlier instructions, comments, answers and handoffs never count. With no human in \
        this chat, never use --approved. Name the commands in a question for @me and leave a \
        handoff instead. Never invent approval words.
        Human-only commands include `task promote`, `task triage`, `doc triage`, `doc edit`, \
        `doc archive` and `ws edit`. The same gate applies to `task edit` unless you hold its \
        claim or use `--print`. Other human-only operations include effective `where \
        --set/--unset` changes, `--steal` over another session's fresh claim, `--force` past an \
        unmet review gate, `--allow-secret`, `restore` except `--dry-run`, `task unblock` \
        unless every task is ready, and proposed-task writes under `proposals: ask`. Before \
        `restore`, run `--dry-run` and show the human its lines. Restore drops work done after \
        the export. Never edit an export tree.
        Keep the baseline comment from `ws show` or a retained editor draft when applying \
        workspace YAML. On `conflict`, review fresh `ws show` output and reapply your edits there. \
        Unstamped YAML uses the configuration at command start.
        To rename an app or topic, change its `slug` and list the old slug in `previous`. \
        `ws show` lists retired slugs. To release one, add `released: {apps: [old-api]}` or \
        `released: {topics: [old-topic]}` and keep the baseline comment. Released references may \
        resolve to a new identity. Preview map changes, alias moves and blockers with \
        `silta --ws acme ws edit --dry-run -F <file>` before requesting approval.
        Set a display label with the optional `name` key under `apps` in workspace YAML. \
        Remove the key to use the slug as the label. Read both with `silta --ws acme ws show` \
        and use the slug in commands and references.
        For a mistaken workspace, preview with `silta ws rm acme --dry-run`. The human runs \
        `silta ws rm acme` in their terminal. The saved default or a live or \
        uninspectable registered clone \
        requires `--allow-active`. Use the printed recovery preview to restore just that workspace.
        Usually propose nothing; never more than two proposals per session, only ideas you \
        would bet the human wants. `task add --start` is only for work the human requested. \
        A subtask of a task you still claim (`task add --parent AC-12`) starts as todo, not \
        as a proposal, so it needs no --approved; submit, block and handoff release the \
        claim. \
        When the human asked in this chat to add the task for later, pass their words as \
        --approved so it becomes todo without triage; do not ask again.
        If brief shows `proposals: ask`, do not propose: name each idea and its exact `silta \
        --ws acme \
        task add` command in your message, then add only the approved ideas with --approved. \
        Without a human, list ideas under "What's left" in a handoff/result, never in a \
        question, TODO comment or file.
        When no answer can come, leave a question for @me listing pending commands, write a \
        handoff and pick other work; do not wait. Under `proposals: ask`, keep unapproved \
        ideas in the handoff/result instead of that question. For "what needs me?", run \
        `silta --ws acme inbox --for me` and relay the displayed choices in one short message. \
        Apply "the rest" only to proposals you showed; ask before running triage.
        """ + "\n"),
    Section(
      topic: "questions",
      text: """
        # Questions
        Ask in chat. Record a question only when blocked beyond this session. Questions \
        default to @me; name recipients explicitly when needed:
        ```sh
        silta --ws acme comment AC-12 --kind question --to me -m 'Which callback URL should \
        Acme use?'
        ```
        Answer with --kind answer and --reply-to <question-ref>. The asker or current task \
        claimer can accept an answer with `silta --ws acme comment accept <answer-ref>`. Answer \
        only as \
        an addressee, or to relay the human's chat answer. Never accept your own answer to a \
        question addressed to a human. Once the addressed human confirms your relay in chat, \
        record it with `comment resolve <question-ref> -m <confirmed answer>`. An answer comment \
        never supplies approval words for a human-only command.
        @me always means human:<USER>, regardless of who runs the command.
        """ + "\n"),
    Section(
      topic: "blocked",
      text: """
        # Blocked
        A question to the human does not block a task. Ask in chat if the human can answer, \
        including questions about the customer. If only an external party (ext:acme) or \
        another task can unblock you, keep doing useful work; block only when none remains.
        Leave a handoff before blocking; blocking releases any remaining claim.
        ```sh
        silta --ws acme comment AC-12 --kind handoff -m 'State: API inspected; Next step: obtain \
        callback URL; Open questions: callback URL; Branch and sha: feature/acme-sign-in at \
        <commit-sha>.'
        silta --ws acme task block AC-12 --on ext:acme -m 'Need the identity provider callback \
        URL.'
        ```
        Use --off <ref> to remove a current blocker. Add its replacement with --on in the same \
        command. Making an unready block ready requires the human's approval.
        Silta sends nothing: tell the human exactly what to ask whom, then pick other work. \
        Never unblock with open blockers without the human's approval, and never put "waiting \
        for" into repo files or plans.
        """ + "\n"),
    Section(
      topic: "handoff",
      text: """
        # Handoff
        Always leave a handoff before stopping. It releases your claim while preserving \
        status. Use the actual branch and sha; the next session reads the task and starts it \
        again. Run `silta session check` to find fresh own claims needing handoff across all \
        workspaces; follow each printed scoped command with the handoff body on stdin.
        ```sh
        silta --ws acme comment AC-12 --kind handoff -F - <<'HANDOFF'
        State: API inspected; implementation remains.
        Next step: implement sign-in and run the verification checks.
        Open questions: none.
        Branch and sha: feature/acme-sign-in at <commit-sha>.
        HANDOFF
        ```
        In the next session, resume with:
        ```sh
        silta --ws acme task show AC-12
        silta --ws acme task start AC-12
        ```
        """ + "\n"),
    Section(
      topic: "reviews",
      text: """
        # Reviews
        Use `silta --ws acme task submit AC-12` to request review. Read discussion with `silta \
        --ws acme task show \
        AC-12`. Reply to the actual finding ref with `silta --ws acme comment AC-12 --reply-to \
        AC-12/3 \
        -m 'Changed the validation; SignInTests proves it.'`, naming what changed and the \
        proving test. Do not resolve review threads yourself unless assigned that \
        responsibility. Post findings as roots, not replies to a handoff; closed code spans \
        and fences are examples, not mentions.
        """ + "\n"),
    Section(
      topic: "refusals",
      text: """
        # Refusals
        Read the error's code, next_by and next commands. A command's next_by can override the \
        code default. Never use --force, --steal, `where --set/--unset`, `task promote` or \
        --allow-secret on your own initiative; name the exact command, wait for the human's \
        reply in this chat, then pass their words through --approved. Never create tracker \
        items, or plan files the repository's instructions don't require. With no human in \
        this chat, see `silta guide human`.
        """ + "\n" + ErrorCode.allCases.map { "  \($0.helpLine)\n" }.joined()),
    Section(
      topic: "refs",
      text: """
        # Reference grammar
        Bare task ids are accepted wherever a task is expected. The grammar is used in \
        arguments and JSON. [[links]] in bodies are not resolved. Parsing a reference does \
        not imply its target exists or is supported by a command.

        | Ref | Example | Notes |
        |---|---|---|
        | Task | `AC-12` | `task:AC-12` is also accepted |
        | Comment | `AC-12/3` | the 3rd comment on AC-12 |
        | Doc / revision / comment | `doc:mobile-auth-flow`, `doc:mobile-auth-flow@4`, \
        `doc:mobile-auth-flow@4/2` | Stored refs resolve |
        | App, topic | `app:platform-api`, `topic:messaging` | |
        | Edge | `edge:platform-api/service:push/sdk` | Map attachment target; \
        task links do not accept edges |
        | Service | `service:push` | Map attachment target; task links do not accept services |
        | Code | `platform-api:src/Api/Controllers/AuthController.cs#L40-52` | `code:` prefix \
        optional except for apps named doc, edge or service; \
        `@<ref>` after the app picks another branch: `platform-api@feature/x:path` |
        | Commit | `code:platform-api@0123456789abcdef0123456789abcdef01234567` | Task link and \
        task list search accept 40 or 64 hexadecimal digits. Stored as a code ref with a literal \
        dot path. |
        | Plan lines | `plan@3#L12-18`, `plan#L12` | latest revision when `@n` is omitted |
        | Diff lines | `diff:lib/push/categories.dart#L88`, `#-L88` for the old side | \
        relative to the task's review subject |
        | Note | `note:notes/projects/acme/2026-10-26-weekly-status.md` | |
        | URL | `url:https://dev.azure.com/…` | |
        | External party | `ext:acme` | 1–64 lowercase letters, digits and `-`, starting and \
        ending with a letter or digit; something a task waits on, never an actor |
        """ + "\n"),
    Section(
      topic: "output",
      text: """
        # Output
        Text is the default; --quiet preserves read output. Use --json only when parsing; it \
        prints the schema-1 envelope on stdout. Errors carry actionable next commands. Use \
        `silta schema` for command shapes and `silta guide refs` for the reference grammar.
        """ + "\n"),
  ]
}

private struct GuideManual: Encodable, Sendable {
  let text: String
  let topics: [String]
  let topic: String?
}

extension GuideCommand {
  private static func render(_ selected: [Section]) -> String {
    selected.map { section in
      (section.topic == "docs" && selected.count > 1 ? docsOverview : section.text)
        + (section.topic == "output"
          ? "Topics: " + sections.map(\.topic).joined(separator: ", ")
            + ". Read one with `silta guide <topic>`.\n" : "")
    }.joined(separator: "\n")
  }
}
