import CryptoKit
package import Foundation

/// Who runs a command (spec §11): a human by name, or an agent tool in a session.
/// Every write records one, so only well-formed values are ever built: each part is
/// 1 to 64 letters, digits, `.`, `_`, `-`, `@` or `+`.
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
    if let explicit = try explicitActor(
      environment: environment, terminal: terminal, session: session)
    {
      return explicit
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
  /// attribution never fails a command over git (§11). Returns warnings for a dropped
  /// override and for a git fault.
  package static func resolve(
    environment: [String: String], terminal: TerminalState, git: any GitRunner, directory: URL
  ) async throws -> (ActorID, [OutputWarning]) {
    var warnings: [OutputWarning] = []
    if environment["SILTA_ACTOR"]?.hasPrefix("human:") == true, !terminal.stdinIsTTY {
      warnings.append(overrideIgnored)
    }
    if let explicit = try explicitActor(environment: environment, terminal: terminal, session: nil)
    {
      return (explicit, warnings)
    }
    let session: String
    if let supplied = environment["SILTA_SESSION"], !supplied.isEmpty {
      guard isPart(supplied) else { throw SeamError.invalidSession }
      session = supplied
    } else {
      let root = await repositoryRoot(git: git, directory: directory)
      if root == .fault { warnings.append(sessionFallback) }
      let path = if case .root(let path) = root { path } else { directory.path }
      session = SHA256.hash(data: Data(path.utf8)).prefix(3)
        .map { String(format: "%02x", $0) }.joined()
    }
    return (try detect(environment: environment, terminal: terminal, session: session), warnings)
  }

  /// Refuses an agent, naming who was detected so a human can see why.
  package func requireHuman(command: StaticString) throws {
    guard isHuman else { throw ActorError.humanOnly(command: command, actor: self) }
  }

  /// `SILTA_ACTOR` as an actor, or nil when it is unset, empty, a `human:` override
  /// without a terminal, or `agent:<tool>` while `session` is still unknown.
  private static func explicitActor(
    environment: [String: String], terminal: TerminalState, session: String?
  ) throws -> ActorID? {
    guard let value = environment["SILTA_ACTOR"], !value.isEmpty else { return nil }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count > 1, parts.dropFirst().allSatisfy(isPart) else {
      throw SeamError.invalidActor
    }
    switch (parts[0], parts.count) {
    case ("human", 2): return terminal.stdinIsTTY ? .human(name: parts[1]) : nil
    case ("agent", 2): return session.map { .agent(tool: parts[1], session: $0) }
    case ("agent", 3): return .agent(tool: parts[1], session: parts[2])
    default: throw SeamError.invalidActor
    }
  }

  private static func isPart(_ value: String) -> Bool {
    value.wholeMatch(of: /[A-Za-z0-9._@+\-]{1,64}/) != nil
  }

  private enum Root: Equatable {
    case root(String)
    case outside
    case fault
  }

  /// The repository's top-level path. A nonzero exit means outside a repository;
  /// anything else unexpected is a git fault.
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
    case .exit?: return .outside
    default: return .fault
    }
  }
}
