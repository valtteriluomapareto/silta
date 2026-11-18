#if DEBUG
  import CoreGraphics
  import Darwin
  import Foundation

  let args = CommandLine.arguments.dropFirst()
  guard let command = args.first, let rawPID = args.dropFirst().first, let pid = Int32(rawPID),
    pid > 0
  else { exit(64) }

  switch command {
  case "identity":
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB)
    else { exit(1) }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let count = proc_pidpath(pid, &path, UInt32(path.count))
    guard count > 0 else { exit(1) }
    let end = path.firstIndex(of: 0) ?? path.count
    let executable = String(decoding: path[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    let identity: [String: Any] = [
      "pid": pid, "seconds": info.pbi_start_tvsec, "microseconds": info.pbi_start_tvusec,
      "executable": executable,
    ]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: identity))
  case "window":
    guard let rawWindow = args.dropFirst(2).first, let number = UInt32(rawWindow),
      CGPreflightScreenCaptureAccess(),
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]],
      windows.contains(where: {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number
          && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
          && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
      })
    else { exit(1) }
  default: exit(64)
  }
#endif
