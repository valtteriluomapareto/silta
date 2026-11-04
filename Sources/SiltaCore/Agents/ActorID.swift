import CryptoKit
package import Foundation

/// Who runs a command (spec §11): a human by name, or an agent tool in a session.
/// Every write records one, so values are validated where they enter (D33).
package enum ActorID: Equatable, Sendable, CustomStringConvertible {
  case human(name: String)
  case agent(tool: String, session: String)

  /// The recorded form: `human:<name>` or `agent:<tool>:<session>`.
  package var description: String {
    switch self {
    case .human(let name): "human:\(name)"
    case .agent(let tool, let session): "agent:\(tool):\(session)"
    }
  }

  /// Human identity is established by detection, not by individual commands.
  package var isHuman: Bool {
    if case .human = self { true } else { false }
  }

  /// Parses a complete actor identity, without attribution or tool-only targets.
  package static func parse(_ value: String) -> ActorID? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 2, parts[0] == "human", isPart(parts[1]) {
      return .human(name: parts[1])
    }
    if parts.count == 3, parts[0] == "agent", isTool(parts[1]), isPart(parts[2]) {
      return .agent(tool: parts[1], session: parts[2])
    }
    return nil
  }

  /// A `human:…` override was dropped because stdin isn't a terminal.
  static let overrideIgnored = OutputWarning(
    code: "actor_override_ignored",
    message: "SILTA_ACTOR=human:… needs stdin to be a terminal, so it was ignored.")

  /// Git failed inside what may be a repository, so the session may differ from the
  /// one the repository root gives.
  static let sessionFallback = OutputWarning(
    code: "session_fallback",
    message: "Git couldn't report the repository root; the session uses the current directory.")

  /// Applies the first matching attribution rule to supplied process state. Empty
  /// `SILTA_ACTOR` counts as unset; a malformed one throws `SeamError.invalidActor`.
  package static func detect(
    environment: [String: String], terminal: TerminalState, session: String
  ) throws -> ActorID {
    switch try explicitActor(environment: environment, terminal: terminal) {
    case .actor(let actor): return actor
    case .agent(let tool): return .agent(tool: tool, session: session)
    case .none, .droppedHuman: break
    }
    if environment["CLAUDECODE"] == "1" { return .agent(tool: "claude", session: session) }
    if environment["CODEX_THREAD_ID"] != nil { return .agent(tool: "codex", session: session) }
    if environment.keys.contains(where: { $0.hasPrefix("OPENCODE_") }) {
      return .agent(tool: "opencode", session: session)
    }
    if !terminal.stdinIsTTY || !terminal.stdoutIsTTY {
      return .agent(tool: "unknown", session: session)
    }
    let user = environment["USER"] ?? ""
    return .human(name: isPart(user) ? user : "unknown")
  }

  /// Resolves the session with one bounded git query unless `SILTA_SESSION` or a
  /// complete `SILTA_ACTOR` supplies it. Outside git, or when git fails in any way, the
  /// session is the current directory's: sessions guard against accidents, so
  /// attribution never fails a command over git (§11). Returns warnings for a git fault,
  /// and for a dropped `human:` override when a human is watching stdout.
  package static func resolve(
    environment: [String: String], terminal: TerminalState, git: any GitRunner, directory: URL
  ) async throws -> (ActorID, [OutputWarning]) {
    let supplied = environment["SILTA_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
    if let supplied, !isPart(supplied) { throw SeamError.invalidSession }
    let explicit = try explicitActor(environment: environment, terminal: terminal)
    if case .actor(let actor) = explicit { return (actor, []) }
    // An agent's shell often inherits a human's exported override; only a human
    // piping into stdin needs telling.
    var warnings: [OutputWarning] =
      explicit == .droppedHuman && terminal.stdoutIsTTY ? [overrideIgnored] : []
    let session: String
    if let supplied {
      session = supplied
    } else {
      let root = await repositoryRoot(git: git, directory: directory)
      if case .fault = root { warnings.append(sessionFallback) }
      let path = if case .root(let path) = root { path } else { directory.path }
      session = SHA256.hash(data: Data(path.utf8)).prefix(3)
        .map { String(format: "%02x", $0) }.joined()
    }
    let actor = try detect(environment: environment, terminal: terminal, session: session)
    // A human's actor carries no session, so a session fallback means nothing to them.
    if actor.isHuman { warnings.removeAll { $0 == sessionFallback } }
    return (actor, warnings)
  }

  /// Accepts a human directly, or an agent carrying the human's words from chat.
  /// Performs no input or storage I/O; callers check state-dependent gates inside
  /// the transaction that performs the mutation.
  @discardableResult
  package func requireHuman(command: String, approved: String? = nil) throws -> HumanApproval? {
    if isHuman { return nil }
    guard let approved else { throw ActorError.humanOnly(command: command, actor: self) }
    let words = approved.trimmingCharacters(in: .whitespacesAndNewlines)
    // The placeholders Silta prints, anywhere in the words, mean they weren't filled in.
    guard (1...300).contains(words.unicodeScalars.count),
      !(words.hasPrefix("<") && words.hasSuffix(">")),
      !words.contains("<the human's words>"), !words.contains("<their words>")
    else { throw ActorError.invalidApproval }
    return HumanApproval(actor: self, words: SecretGuard.redacted(words))
  }

  /// Reports unused words or redaction without retaining the original quote.
  package func approvalWarnings(_ words: String?, used: Bool) -> [OutputWarning] {
    guard let words else { return [] }
    if isHuman || !used {
      return [
        OutputWarning(
          code: "approval_unused",
          message: "This command did not need --approved; no approval stored.")
      ]
    }
    return SecretGuard.matches(in: words).isEmpty ? [] : [SecretGuard.warning]
  }

  private enum Explicit: Equatable {
    case none
    case droppedHuman
    case actor(ActorID)
    /// `agent:<tool>`, which takes the resolved session.
    case agent(String)
  }

  /// `SILTA_ACTOR`, parsed once. A `human:` override needs stdin to be a terminal.
  private static func explicitActor(
    environment: [String: String], terminal: TerminalState
  ) throws -> Explicit {
    guard let value = environment["SILTA_ACTOR"], !value.isEmpty else { return .none }
    if let actor = parse(value) {
      return actor.isHuman && !terminal.stdinIsTTY ? .droppedHuman : .actor(actor)
    }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    switch (parts[0], parts.count) {
    case ("agent", 2) where isTool(parts[1]): return .agent(parts[1])
    default: throw SeamError.invalidActor
    }
  }

  /// A name or session: letters, digits, `.`, `_` and `-`, starting and ending with a
  /// letter or digit, so a mention like `@human:acme.` ends before the full stop.
  private static func isPart(_ value: String) -> Bool {
    value.wholeMatch(of: /[A-Za-z0-9]([A-Za-z0-9._\-]{0,62}[A-Za-z0-9])?/) != nil
  }

  /// A tool is lowercase, so `agent:Claude` can't become a second claimant.
  private static func isTool(_ value: String) -> Bool {
    value.wholeMatch(of: /[a-z0-9]([a-z0-9\-]{0,62}[a-z0-9])?/) != nil
  }

  private enum Root {
    case root(String)
    case outside
    case fault
  }

  /// The repository's top-level path. Only git's own "not a git repository" means
  /// outside one (stderr is stable under the runner's `LC_ALL=C`); anything else,
  /// such as dubious ownership or a corrupt repository, is a fault.
  private static func repositoryRoot(git: any GitRunner, directory: URL) async -> Root {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let result = try? await git.run(request)  // a spawn failure is a fault, handled below
    switch result?.termination {
    case .exit(0)?:
      var bytes = result?.stdout ?? Data()
      if bytes.last == 10 { bytes.removeLast() }
      guard let root = String(data: bytes, encoding: .utf8), root.hasPrefix("/") else {
        return .fault
      }
      return .root(root)
    case .exit?:
      let stderr = String(bytes: result?.stderr ?? Data(), encoding: .utf8) ?? ""
      return stderr.contains("not a git repository") ? .outside : .fault
    default: return .fault
    }
  }
}
