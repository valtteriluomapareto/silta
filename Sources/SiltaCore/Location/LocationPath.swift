import Darwin
import Foundation

enum LocationPath {
  static func canonical(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw LocationError.invalidPath }
    defer { free(path) }
    let resolved = URL(filePath: String(cString: path))
    let values = try resolved.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values.volumeSupportsCaseSensitiveNames == false
      ? URL(filePath: resolved.path.lowercased()) : resolved
  }

  static func contains(_ root: URL, _ path: URL) -> Bool {
    path.path == root.path || path.path.hasPrefix(root.path + "/")
  }
}
