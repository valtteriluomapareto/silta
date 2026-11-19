package import Darwin
package import Foundation

/// Reads a limited byte stream or opens a regular file for bounded input.
package enum BoundedInput {
  /// The supplied body byte ceiling shared by the CLI and document validation.
  package static let maximumBodyBytes = 64 * 1024

  /// Reads at most one byte past the limit and reports overflow before waiting for EOF.
  package static func read(
    maximum: Int, nextBytes: (Int) throws -> Data?
  ) throws -> Data {
    var bytes = Data()
    while let chunk = try nextBytes(maximum - bytes.count + 1), !chunk.isEmpty {
      bytes.append(chunk)
      guard bytes.count <= maximum else { throw BodyInputError.tooLarge(maximum) }
    }
    return bytes
  }

  /// Opens a regular file and returns attributes of the same open descriptor.
  package static func openRegular(
    _ path: String, followSymlinks: Bool = true
  ) throws -> (handle: FileHandle, info: stat) {
    var info = stat()
    let inspected = followSymlinks ? stat(path, &info) : lstat(path, &info)
    guard inspected == 0 else { throw BodyInputError.unreadable }
    guard info.st_mode & S_IFMT == S_IFREG else { throw BodyInputError.notRegular }
    // The path can change after inspection. A replacement FIFO must not block open.
    let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW)
    let descriptor = open(path, flags)
    guard descriptor >= 0 else { throw BodyInputError.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard fstat(descriptor, &info) == 0 else { throw BodyInputError.unreadable }
    guard info.st_mode & S_IFMT == S_IFREG else { throw BodyInputError.notRegular }
    return (handle, info)
  }
}

/// Body transport failures carry no body, file path or approval words.
package enum BodyInputError: CodedError {
  /// The selected source could not be opened, inspected, or read.
  case unreadable
  /// The opened named source is not a regular file.
  case notRegular
  /// Reading crossed the supplied byte limit.
  case tooLarge(Int)
  /// The supplied bytes could not be decoded as UTF-8.
  case invalidUTF8

  /// Supplied input with an unsupported source, size or encoding is invalid.
  package var code: ErrorCode {
    .invalid
  }

  /// Describes how to prepare a replacement body.
  package var message: String {
    switch self {
    case .unreadable: "Cannot read body input. Check its path and permissions."
    case .notRegular: "Body input requires a regular file or standard input."
    case .tooLarge(let maximum): "Body input exceeds \(maximum) bytes."
    case .invalidUTF8: "Body input must be valid UTF-8."
    }
  }

  /// The CLI substitutes help for the actual command.
  package var next: [String] {
    ["silta --help"]
  }
}
