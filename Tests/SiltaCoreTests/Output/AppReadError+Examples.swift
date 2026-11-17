@testable import SiltaAppSupport
@testable import SiltaCore

extension AppReadError: ErrorExamples {
  static var examples: [AppReadError] {
    [.migrationRequired] + StorageError.allCases.map { AppReadError($0) }
  }
}
