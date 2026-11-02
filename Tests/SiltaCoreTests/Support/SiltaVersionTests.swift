import SiltaCore
import Testing

struct SiltaVersionTests {
  @Test func currentIsMajorMinorPatch() {
    #expect(SiltaVersion.current.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
  }
}
