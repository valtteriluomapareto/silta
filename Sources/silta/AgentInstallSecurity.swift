import Darwin
import Foundation

/// Rejects protections an atomic replacement cannot retain without copying security state.
enum AgentInstallSecurity {
  static func file(
    _ fd: Int32, parent: Int32, info: stat, refusal: () throws -> Never
  ) throws -> String {
    var directory = stat()
    guard fstat(parent, &directory) == 0, info.st_uid == geteuid(),
      info.st_gid == directory.st_gid, info.st_flags == 0, info.st_mode & 0o7000 == 0
    else { try refusal() }
    try acl(fd, directory: false, refusal: refusal)
    let count = flistxattr(fd, nil, 0, 0)
    guard count >= 0, count <= 1_048_576 else { try refusal() }
    if count > 0 {
      var names = Data(count: count)
      let read = names.withUnsafeMutableBytes {
        flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0)
      }
      guard read == count, let text = String(data: names, encoding: .utf8),
        text.split(separator: "\0").allSatisfy({ $0 == "com.apple.provenance" })
      else { try refusal() }
    }
    return "\(info.st_uid):\(info.st_gid)"
  }

  static func directory(_ fd: Int32, refusal: () throws -> Never) throws {
    try acl(fd, directory: true, refusal: refusal)
  }

  private static func acl(
    _ fd: Int32, directory: Bool, refusal: () throws -> Never
  ) throws {
    errno = 0
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
      guard errno == ENOENT || errno == ENOATTR else { try refusal() }
      return
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_valid(acl) == 0 else { try refusal() }
    var entry: acl_entry_t?
    var index = Int32(ACL_FIRST_ENTRY.rawValue)
    while acl_get_entry(acl, index, &entry) == 0 {
      guard directory, let entry else { try refusal() }
      var flags: acl_flagset_t?
      guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
        acl_get_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 0,
        acl_get_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 0
      else { try refusal() }
      index = Int32(ACL_NEXT_ENTRY.rawValue)
    }
    // Darwin reports the end of a valid ACL's entries as EINVAL.
    guard errno == EINVAL else { try refusal() }
  }
}
