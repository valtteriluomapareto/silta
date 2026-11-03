import Foundation
@testable import SiltaCore
import Testing

/// A `CodedError` type and examples of every case it can produce.
protocol ErrorExamples: CodedError {
  static var examples: [Self] { get }
}

extension UsageError: ErrorExamples {
  static var examples: [UsageError] {
    [
      .usage(message: "Unknown option '--nope'", command: "silta"),
      .invalid(message: "--limit must be positive", command: "silta task ls"),
    ]
  }
}

extension InternalError: ErrorExamples {
  struct Sample: Error, CustomStringConvertible {
    var description = "index out of range"
  }

  static var examples: [InternalError] { [InternalError(Sample())] }
}

extension SchemaError: ErrorExamples {
  static var examples: [SchemaError] { [.unknownCommand("silta nope", known: ["silta schema"])] }
}

extension SeamError: ErrorExamples {
  static var examples: [SeamError] { Array(allCases) }
}

extension StorageError: ErrorExamples {
  static var examples: [StorageError] { Array(allCases) }
}

extension SecretError: ErrorExamples {
  static var examples: [SecretError] {
    [SecretError(command: "silta task add '<title>' -F <file>", text: "Pwd=acme-secret")]
  }
}

extension WorkspaceError: ErrorExamples {
  static var examples: [WorkspaceError] {
    [.invalid(["line 1: expected a mapping"]), .notFound, .conflict, .editor, .input]
  }
}

extension RepoError: ErrorExamples {
  static var examples: [RepoError] {
    [
      .scan, .notFound, .localPath(repo: "platform", workspace: "acme"),
      .configuration(repo: "platform", workspace: "acme"), .duplicateSlug,
      .fetch(repo: "platform", workspace: "acme"),
    ]
  }
}

extension TaskError: ErrorExamples {
  static var examples: [TaskError] {
    [
      .notFound, .invalid("A result is required."),
      .claimed("AC-1", holder: "agent:codex:acme", minutes: 4), .proposal("AC-1"),
      .transition("AC-1", status: "done"), .git, .repository, .input, .foreignRepo, .gate("AC-1"),
      .promoted("AC-1", external: "ado:42"), .edited("AC-1"),
      .blocked(
        "AC-1", TaskWaiting(on: ["ext:acme"], ageDays: 2, why: "Acme", ready: false, dropped: [])),
      .blocked(
        "AC-2", TaskWaiting(on: ["task:AC-1"], ageDays: 1, why: "Acme", ready: true, dropped: [])),
      .changed("AC-1"), .staleRev("AC-1", actual: 2), .blockedPromotion("AC-1"),
    ]
  }
}

extension TaskReferenceError: ErrorExamples {
  static var examples: [TaskReferenceError] {
    [.init(ref: "AC-1", missing: true), .init(ref: "AC-0", missing: false)]
  }
}

extension CommandFailure: ErrorExamples {
  static var examples: [CommandFailure] {
    [.init(error: StorageError.busy, next: ["silta task add"])]
  }
}

extension ActorError: ErrorExamples {
  static var examples: [ActorError] {
    [
      .humanOnly(command: "silta task triage", actor: .agent(tool: "unknown", session: "acme")),
      .notReady(
        command: "silta task unblock 'AC-4' 'AC-7'", actor: .agent(tool: "codex", session: "acme"),
        refs: ["AC-4", "AC-7"]),
      .invalidApproval,
    ]
  }
}

/// Proves every `ErrorCode` is produced by some error type (spec §16, D22).
///
/// This shows each code is *mapped* by a registered type's examples, not that a
/// command raises it at run time; the CLI goldens cover that per command.
struct ErrorReachabilityTests {
  /// Every `CodedError` type in `Sources/`. A new type must be added here.
  static let registry: [any ErrorExamples.Type] = [
    UsageError.self, InternalError.self, SchemaError.self, SeamError.self, SecretError.self,
    StorageError.self, ActorError.self, WorkspaceError.self, RepoError.self, TaskError.self,
    CommandFailure.self, TaskReferenceError.self,
  ]

  /// Codes no slice produces yet. A slice that adds an error type removes its codes.
  static let notYetProduced: Set<ErrorCode> = [
    .unregistered, .ambiguousLocation,
    .leaseTaken, .rateLimited,
  ]

  static var examples: [any CodedError] {
    registry.flatMap { type in type.examples.map { $0 as any CodedError } }
  }

  @Test func everyCodeIsProducedOrListedAsPending() {
    let produced = Set(Self.examples.map(\.code))
    #expect(
      produced.isDisjoint(with: Self.notYetProduced), "produced codes still listed as pending")
    #expect(produced.union(Self.notYetProduced) == Set(ErrorCode.allCases))
  }

  @Test func examplesFollowTheContract() {
    for error in Self.examples {
      #expect(!error.message.isEmpty && !error.message.contains("\n"), "\(error.code)")
      #expect(!error.next.isEmpty, "\(error.code) has no next command")
      if error.retryAfter != nil {
        #expect([.rateLimited, .busy].contains(error.code), "\(error.code) sets retryAfter")
      }
    }
  }

  @Test func everyCodedErrorTypeInSourcesIsRegistered() throws {
    let sources = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources")
    var text = ""
    let files = try #require(FileManager.default.enumerator(atPath: sources.path))
    for case let path as String in files where path.hasSuffix(".swift") {
      text += try String(contentsOf: sources.appending(path: path), encoding: .utf8) + "\n"
    }
    #expect(codedErrorTypes(in: text) == Set(Self.registry.map { String(describing: $0) }))
  }

  @Test func scanFindsEveryWayToConform() {
    let planted = """
      enum A: CodedError {}
      struct B: Equatable, CodedError {}
      final class C: CodedError {}
      actor D: CodedError {}
      extension E: CodedError {}
      protocol AreaError: CodedError {}
      enum F: AreaError {}
      // enum G: CodedError {}
      protocol CodedError: Error {}
      """
    #expect(codedErrorTypes(in: planted) == ["A", "B", "C", "D", "E", "F"])
  }

  /// Names of types conforming to `CodedError` in `text`, directly or through a
  /// protocol that refines it. A regex scan: generic types (`struct G<T>: …`),
  /// qualified names (`extension A.B: …`) and `where` clauses are invisible to it.
  private func codedErrorTypes(in text: String) -> Set<String> {
    let code = text.split(separator: "\n").filter {
      !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }.joined(separator: "\n")
    var protocols: Set<String> = ["CodedError"]
    var types: Set<String> = []
    var changed = true
    while changed {
      changed = false
      for match in code.matches(
        of: /(protocol|struct|enum|class|actor|extension)\s+(\w+)\s*:([^{]*)\{/)
      {
        let (kind, name, inherited) = (match.output.1, String(match.output.2), match.output.3)
        let conforms = inherited.split(separator: ",").contains {
          protocols.contains($0.trimmingCharacters(in: .whitespaces))
        }
        guard conforms else { continue }
        if kind == "protocol" {
          changed = protocols.insert(name).inserted || changed
        } else {
          types.insert(name)
        }
      }
    }
    return types
  }
}
