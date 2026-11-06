import Foundation
import SiltaTestSupport
import Testing

struct ShapeCheckTests {
  private func json(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
  }

  private let shape =
    #"{"object":{"n":"int","s":"string","b":"bool","a":{"array":"string"},"#
    + #""o":{"optional":"int"},"x":"any"}}"#

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
    #"{"n":true,"s":"a","b":true,"a":[],"x":0}"#,  // a bool where an int belongs
    #"{"n":1,"s":"a","b":true,"a":[],"x":0,"o":"x"}"#,  // present optional, wrong type
    #"{"n":1,"s":"a","b":true,"a":"x","x":0}"#,  // not an array
    #"[]"#,  // not an object
  ])
  func mismatchIsReported(value: String) throws {
    #expect(ShapeCheck.violations(of: try json(value), against: try json(shape)).count == 1)
  }

  @Test func violationsNameThePath() throws {
    let value = #"{"n":1,"s":"a","b":true,"a":["x",2],"x":0}"#
    #expect(
      ShapeCheck.violations(of: try json(value), against: try json(shape))
        == ["data.a[1]: expected string, got a number"])
  }

  @Test(arguments: [#""float""#, #"{"foo":"int"}"#, #"{"optional":"int"}"#])
  func unknownShapeIsReported(shape: String) throws {
    #expect(ShapeCheck.violations(of: 1, against: try json(shape)).count == 1)
  }
}
