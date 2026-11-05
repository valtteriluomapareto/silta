import Foundation
import SiltaTestSupport
import Testing

/// The last step of `dogfood-report.sh --ws <slug>`: the report is published at its own
/// path and nowhere else, whatever already sits at that path or at the folders the script
/// owns.
@Suite(.timeLimit(.minutes(2)))
struct DogfoodPrivateReportPublicationTests {
  typealias Report = DogfoodReportTests

  /// Every regular file under `folder`, symlinks not followed.
  static func files(under folder: URL) -> [String] {
    let walker = FileManager.default.enumerator(atPath: folder.path)
    var found: [String] = []
    while let relative = walker?.nextObject() as? String {
      if walker?.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
        found.append(relative)
      }
    }
    return found.sorted()
  }

  /// Puts `layout` at the report's own path or folder; returns the repository it may point
  /// into and the text the refusal must contain.
  static func occupy(_ layout: String, scratch: URL) throws -> (repo: URL, refusal: String) {
    let fm = FileManager.default
    let repo = scratch.appending(path: "acme-repo")
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try DogfoodInstallTests.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
    let reports = scratch.appending(path: "silta-home/reports")
    let folder = reports.appending(path: "silta")
    let target = folder.appending(path: "2023-11-30.md")
    switch layout {
    case "linked-target-into-a-repo":
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: target, withDestinationURL: repo)
      return (repo, target.path + " already exists")
    case "dangling-target-into-a-repo":
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: target, withDestinationURL: repo.appending(path: "out.md"))
      return (repo, target.path + " already exists")
    case "directory-target":
      try fm.createDirectory(at: target, withIntermediateDirectories: true)
      return (repo, target.path + " already exists")
    case "linked-folder":
      let elsewhere = scratch.appending(path: "elsewhere")
      try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
      try fm.createDirectory(at: reports, withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
      return (repo, folder.path + " is a symlink")
    default:
      let elsewhere = scratch.appending(path: "elsewhere")
      try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: reports, withDestinationURL: elsewhere)
      return (repo, reports.path + " is a symlink")
    }
  }

  @Test(arguments: [
    "linked-target-into-a-repo", "dangling-target-into-a-repo", "directory-target",
    "linked-folder", "linked-reports-root",
  ])
  func publicationNeverFollowsWhatIsAlreadyThere(layout: String) throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let occupied = try Self.occupy(layout, scratch: scratch)
      let result = try Report.run(
        ["--ws", "silta", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(1) && result.stdout.isEmpty)
      #expect(result.stderr.contains(occupied.refusal), "\(result.stderr)")
      let status = try DogfoodInstallTests.git(
        ["status", "--short", "--untracked-files=all", "--ignored"], in: scratch,
        cwd: occupied.repo)
      #expect(status.isEmpty, "\(status)")
      #expect(Self.files(under: scratch.appending(path: "elsewhere")).isEmpty)
      let reports = Self.files(under: scratch.appending(path: "silta-home")).filter {
        $0.hasSuffix(".md") || $0.contains(".report.")
      }
      #expect(reports.isEmpty, "\(reports)")
    }
  }
}
