import Foundation
import SiltaCore
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

/// Proves every `ErrorCode` is produced by some error type (spec §16, D22).
///
/// This shows each code is *mapped* by a registered type's examples, not that a
/// command raises it at run time; the CLI goldens cover that per command.
struct ErrorReachabilityTests {
  /// Every `CodedError` type in `Sources/`. A new type must be added here.
  static let registry: [any ErrorExamples.Type] = [UsageError.self, InternalError.self]

  /// Codes no slice produces yet. A slice that adds an error type removes its codes.
  static let notYetProduced: Set<ErrorCode> = [
    .notFound, .unregistered, .humanOnly, .readOnlyPromoted, .ambiguousLocation, .busy,
    .conflict, .claimed, .staleRev, .leaseTaken, .gate, .rateLimited,
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
    let declaration = /(?:struct|enum|class)\s+(\w+)[^{]*\bCodedError\b/
    var found: Set<String> = []
    let files = try #require(FileManager.default.enumerator(atPath: sources.path))
    for case let path as String in files where path.hasSuffix(".swift") {
      let text = try String(contentsOf: sources.appending(path: path), encoding: .utf8)
      for match in text.matches(of: declaration) {
        found.insert(String(match.output.1))
      }
    }
    #expect(found == Set(Self.registry.map { String(describing: $0) }))
  }
}
