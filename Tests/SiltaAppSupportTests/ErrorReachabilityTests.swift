import SiltaCore
@testable import SiltaAppSupport
import Testing

struct ErrorReachabilityTests {
  @Test(arguments: [StorageError.busy, .cannotOpen, .schemaTooNew])
  func appFailureRetainsTheCodedRecoveryContract(_ underlying: StorageError) {
    let error: any CodedError = AppReadError(underlying)
    #expect(error.code == underlying.code)
    #expect(error.message == underlying.message)
    #expect(error.next == underlying.next)
    #expect(error.retryAfter == underlying.retryAfter)
    #expect(error.nextBy == underlying.nextBy)
  }
}
