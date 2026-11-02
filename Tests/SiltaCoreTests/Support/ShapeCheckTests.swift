import Foundation
import SiltaTestSupport
import Testing

struct ShapeCheckTests {
  private func json(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
  }

  private let shape = #"{"object":{"n":"int","s":"string","b":"bool","a":{"array":"string"},"o":{"optional":"int"},"x":"any"}}"#

  @Test func matchingValuePasses() throws {
    let value = #"{"n":1,"s":"a","b":true,"a":["x"],"x":{"anything":[1]}}"#
    #expect(ShapeCheck.violations(of: try json(value), against: try json(shape)) == [])
  }

  @Test(arguments: [
    #"{"n":"1","s":"a","b":true,"a":[],"x":0}"#,  // wrong type
    #"{"s":"a","b":true,"a":[],"x":0}"#,  // missing required field
    #"{"n":1,"s":"a","b":true,"a":[],"x":0,"extra":1}"#,  // field not in the shape
    #"{"n":1,"s":"a","b":1,"a":[],"x":0}"#,  // number where a bool belongs
    #"{"n":1,"s":"a","b":true,"a":[2],"x":0}"#,  // wrong element type
    #"{"n":1.5,"s":"a","b":true,"a":[],"x":0}"#,  // not an integer
  ])
  func mismatchIsReported(value: String) throws {
    #expect(ShapeCheck.violations(of: try json(value), against: try json(shape)).count == 1)
  }

  @Test func unknownShapeIsReported() throws {
    #expect(ShapeCheck.violations(of: 1, against: "float").count == 1)
  }
}
