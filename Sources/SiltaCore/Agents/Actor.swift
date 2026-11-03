import CryptoKit
package import Foundation

/// Attribution and human-only policy for a command (spec §11).
package struct Actor: Equatable, Sendable {
  /// The complete actor string recorded on writes and diagnostics.
  package let value: String
  /// Human identity is established by detection, not by individual commands.
  package var isHuman: Bool {
    value.hasPrefix("human:")
  }

  /// Applies the first matching attribution rule to supplied process state.
  package static func detect(
    environment: [String: String], terminal: TerminalState, session: String
  ) -> Actor {
    if let explicit = explicitActor(environment: environment, terminal: terminal) {
      return Actor(value: explicit)
    }
    if environment["CLAUDECODE"] == "1" { return Actor(value: "agent:claude:" + session) }
    if environment["CODEX_THREAD_ID"] != nil { return Actor(value: "agent:codex:" + session) }
    if environment.keys.contains(where: { $0.hasPrefix("OPENCODE_") }) {
      return Actor(value: "agent:opencode:" + session)
    }
    if !terminal.stdinIsTTY || !terminal.stdoutIsTTY {
      return Actor(value: "agent:unknown:" + session)
    }
    return Actor(value: "human:" + (environment["USER"] ?? "unknown"))
  }

  /// Resolves the session with one bounded git query unless an override supplies it.
  /// A supplied actor needs no session query. Outside git, or when git fails in any way,
  /// the session is the current directory's: sessions guard against accidents, so
  /// attribution must never fail a command (§11).
  package static func resolve(
    environment: [String: String], terminal: TerminalState, git: any GitRunner, directory: URL
  ) async -> Actor {
    if let explicit = explicitActor(environment: environment, terminal: terminal) {
      return Actor(value: explicit)
    }
    let session: String
    if let supplied = environment["SILTA_SESSION"] {
      session = supplied
    } else {
      let path = await repositoryRoot(git: git, directory: directory) ?? directory.path
      session = SHA256.hash(data: Data(path.utf8)).prefix(3)
        .map { String(format: "%02x", $0) }.joined()
    }
    return detect(environment: environment, terminal: terminal, session: session)
  }

  /// The repository's top-level path, or nil outside git or on any git fault.
  private static func repositoryRoot(git: any GitRunner, directory: URL) async -> String? {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let result = try? await git.run(request)  // a git fault means no repository root
    guard let result, result.termination == .exit(0) else { return nil }
    var bytes = result.stdout
    if bytes.last == 10 { bytes.removeLast() }
    guard let root = String(data: bytes, encoding: .utf8), root.hasPrefix("/") else { return nil }
    return root
  }

  /// Refuses agent execution with a fixed, body-free command for a human to run.
  package func requireHuman(command: StaticString) throws {
    guard isHuman else { throw ActorError.humanOnly(command: command) }
  }

  private static func explicitActor(
    environment: [String: String], terminal: TerminalState
  ) -> String? {
    guard let value = environment["SILTA_ACTOR"] else { return nil }
    return value.hasPrefix("human:") && !terminal.stdinIsTTY ? nil : value
  }
}
