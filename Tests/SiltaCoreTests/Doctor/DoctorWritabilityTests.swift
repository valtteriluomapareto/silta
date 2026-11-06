import Darwin
import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

struct DoctorWritabilityTests {
  private func permissions(_ file: FileHandle) throws -> Int {
    var info = stat()
    try #require(fstat(file.fileDescriptor, &info) == 0)
    return Int(info.st_mode & 0o7777)
  }

  private func permissions(_ directory: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    ).intValue
  }

  private func inspect(_ home: URL) async -> DoctorReport {
    await DoctorService.inspect(
      store: StorageSchemaTests.store(home), home: home,
      git: ScriptedGitRunner(script: [
        (
          GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
          .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50\n".utf8)))
        )
      ]), at: StorageSchemaTests.instant)
  }

  @Test(arguments: ["file", "directory-write", "directory-search"])
  func deniedAccessIsFailedWithoutRepairs(kind: String) async throws {
    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let file = URL(filePath: store.path)
      let before = try Data(contentsOf: file)
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }  // best-effort fixture cleanup
      let target = kind == "file" ? file : home
      let mode = kind == "file" ? 0o400 : kind == "directory-write" ? 0o500 : 0o600
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: kind == "file" ? 0o600 : 0o700], ofItemAtPath: target.path)
      }  // restore fixture access
      try #require(
        kind == "directory-search"
          ? !FileManager.default.isExecutableFile(atPath: home.path)
          : !FileManager.default.isWritableFile(atPath: target.path))
      let fileMode = try permissions(handle)
      let directoryMode = try permissions(home)
      let report = await inspect(home)
      #expect(try permissions(handle) == fileMode)
      #expect(try permissions(home) == directoryMode)
      let check = try #require(report.checks.first { $0.id == "database.writable" })
      #expect(check.status == .fail)
      #expect(check.nextBy == .human)
      #expect(check.next == ["/bin/ls -ld " + shellWord(file.path) + " " + shellWord(home.path)])
      #expect(!report.checks.flatMap(\.next).contains("silta init"))
      #expect(DoctorFailure(report: report).code == .env)
      #expect(DoctorFailure(report: report).nextBy == .human)
      if kind != "directory-search" {
        #expect(report.checks.first { $0.id == "database.integrity" }?.status == .pass)
        #expect(report.checks.first { $0.id == "data.claims" }?.status == .pass)
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: kind == "file" ? 0o600 : 0o700], ofItemAtPath: target.path)
      #expect(try Data(contentsOf: file) == before)
    }
  }

  @Test func healthyAccessIsOnlyAPreflightAndLeavesTruthUnchanged() async throws {
    try await withScratchDirectory { home in
      do { try StorageSchemaTests.store(home).initialize() }
      let file = home.appending(path: "silta.db")
      let before = try Data(contentsOf: file)
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.id == "database.writable" })
      #expect(check.status == .pass)
      #expect(check.message.contains("preflight"))
      #expect(check.next.isEmpty)
      #expect(try Data(contentsOf: file) == before)
    }
  }

  @Test func missingDatabaseIsSkippedWithoutCreation() async throws {
    try await withScratchDirectory { home in
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.id == "database.writable" })
      #expect(check.status == .skipped)
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: "silta.db").path))
    }
  }

  @Test func nonregularDatabaseCannotPassWritability() async throws {
    try await withScratchDirectory { home in
      try FileManager.default.createDirectory(
        at: home.appending(path: "silta.db"), withIntermediateDirectories: true)
      let report = await inspect(home)
      #expect(report.checks.first { $0.id == "database.writable" }?.status == .fail)
    }
  }

  @Test func linkedDatabaseChecksTheTargetDirectory() async throws {
    try await withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let target = scratch.appending(path: "target")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      do { try StorageSchemaTests.store(target).initialize() }
      try FileManager.default.createSymbolicLink(
        at: home.appending(path: "silta.db"),
        withDestinationURL: target.appending(path: "silta.db"))
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: target.path)
      }  // restore fixture access
      try #require(!FileManager.default.isWritableFile(atPath: target.path))
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.id == "database.writable" })
      #expect(check.status == .fail)
      #expect(
        check.next == [
          "/bin/ls -ld " + shellWord(target.appending(path: "silta.db").path) + " "
            + shellWord(target.path)
        ])
    }
  }
}
