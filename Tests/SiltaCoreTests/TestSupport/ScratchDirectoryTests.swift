import Foundation
import SiltaTestSupport
import Testing

struct ScratchDirectoryTests {
  private struct Planted: Error {}

  @Test func givesAnEmptyDirectoryAndRemovesIt() throws {
    let url = try withScratchDirectory { url in
      let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
      #expect(contents.isEmpty)
      return url
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func removesTheDirectoryWhenTheBodyThrows() throws {
    var seen: URL?
    #expect(throws: Planted.self) {
      try withScratchDirectory { url in
        seen = url
        throw Planted()
      }
    }
    let url = try #require(seen)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}
