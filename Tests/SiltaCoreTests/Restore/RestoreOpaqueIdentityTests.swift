import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreOpaqueIdentityTests {
  @Test func doctorDiagnosesStoredUnicodeIdentitiesWithoutRepair() throws {
    try withScratchDirectory { home in
      let store = try RestoreOpaqueIdentityFixture.documents(home)
      let before = try RestoreSupport.dump(store)
      let raw = try RestoreASCIIIdentityTests.rawUIDs(store, table: "doc")
      try #require(raw.count == 3)
      #expect(Set(raw).count == 3)
      let error = RestoreASCIIIdentityTests.failure {
        _ = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      }
      #expect(error == nil)
      let integrity = StoredUIDAdmissionTests.checks(store, home: home).first {
        $0.id == "database.integrity"
      }
      #expect(integrity?.status == .fail && integrity?.message.contains("ASCII") == true)
      #expect(try RestoreSupport.dump(store) == before)
      #expect(try RestoreASCIIIdentityTests.rawUIDs(store, table: "doc") == raw)
    }
  }
}
