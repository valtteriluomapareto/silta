import Foundation

/// Checks decoded JSON against a shape as `silta schema --json` publishes it
/// (spec §20.1), so a command's `--json` tests can prove its data matches its schema.
package enum ShapeCheck {
  /// One description per mismatch, with the path; empty when `value` fits `shape`.
  package static func violations(of value: Any, against shape: Any, at path: String = "data")
    -> [String]
  {
    switch shape {
    case let name as String:
      return matches(value, name) ? [] : ["\(path): expected \(name), got \(describe(value))"]
    case let wrapper as [String: Any]:
      if let element = wrapper["array"] {
        guard let items = value as? [Any] else { return ["\(path): expected an array"] }
        return items.enumerated().flatMap {
          violations(of: $1, against: element, at: "\(path)[\($0)]")
        }
      }
      if let fields = wrapper["object"] as? [String: Any] {
        return object(value, fields: fields, at: path)
      }
      return ["\(path): unknown shape \(wrapper)"]
    default:
      return ["\(path): unknown shape \(shape)"]
    }
  }

  private static func object(_ value: Any, fields: [String: Any], at path: String) -> [String] {
    guard let object = value as? [String: Any] else { return ["\(path): expected an object"] }
    var found = object.keys.filter { fields[$0] == nil }.sorted().map {
      "\(path).\($0): not in the shape"
    }
    for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
      let optional = (field as? [String: Any])?["optional"]
      guard let member = object[name] else {
        if optional == nil { found.append("\(path).\(name): missing") }
        continue
      }
      found += violations(of: member, against: optional ?? field, at: "\(path).\(name)")
    }
    return found
  }

  private static func matches(_ value: Any, _ name: String) -> Bool {
    let number = value as? NSNumber
    let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    switch name {
    case "string": return value is String
    case "bool": return isBool
    case "int": return number.map { !isBool && $0.doubleValue == $0.doubleValue.rounded() } ?? false
    case "any": return true
    default: return false
    }
  }

  private static func describe(_ value: Any) -> String {
    String(describing: type(of: value))
  }
}
