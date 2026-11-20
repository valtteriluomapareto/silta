import Foundation
import SiltaCore

enum BodyInput {
  static func read(_ source: String) throws -> String {
    do {
      let handle =
        try source == "-" ? FileHandle.standardInput : BoundedInput.openRegular(source).handle
      let bytes = try BoundedInput.read(maximum: BoundedInput.maximumBodyBytes) {
        try handle.read(upToCount: $0)
      }
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw BodyInputError.invalidUTF8
      }
      return text
    } catch let error as BodyInputError {
      throw error
    } catch {
      throw BodyInputError.unreadable
    }
  }
}
