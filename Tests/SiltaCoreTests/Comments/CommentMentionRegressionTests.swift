@testable import SiltaCore
import Testing

struct CommentMentionRegressionTests {
  @Test(arguments: ["@me-other", "@me:other"])
  func aliasPrefixesNeverRedirectToHuman(body: String) throws {
    withKnownIssue("#13: @me must be a complete alias") {
      let actors = try CommentMentions.parse(
        body, to: [], human: .human(name: "acme"), question: false)
      #expect(actors.isEmpty)
    }
  }

  @Test(arguments: ["**@human:acme**", "`@human:acme`", "@human:acme: please check"])
  func wrappedMentionsKeepTheirActor(body: String) throws {
    withKnownIssue("#13: Markdown delimiters must not be part of actor mentions") {
      let actors = try CommentMentions.parse(
        body, to: [], human: .human(name: "acme"), question: false)
      #expect(actors == ["human:acme"])
    }
  }
}
