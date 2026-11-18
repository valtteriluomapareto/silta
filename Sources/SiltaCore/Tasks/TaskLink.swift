import Foundation

/// A task link rendered using the shared reference vocabulary.
package struct TaskLink: Encodable, Equatable, Sendable {
  /// Describes the relationship to the target.
  package let rel: String

  /// Identifies an internal or external target.
  package let target: String
}

extension TaskLink {
  /// Masks secrets in either literal or percent-encoded display targets.
  package var displayTarget: String {
    let decoded = target.removingPercentEncoding ?? target
    return SecretGuard.matches(in: decoded).isEmpty
      ? SecretGuard.redacted(target) : SecretGuard.redacted(decoded)
  }
}
