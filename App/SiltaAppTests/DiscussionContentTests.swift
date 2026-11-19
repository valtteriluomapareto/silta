#if DEBUG
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  struct DiscussionContentTests {
    private func post(
      _ ref: String, _ actor: String = "agent:claude:review", kind: String = "comment",
      replyTo: String? = nil, resolved: Bool = false, deleted: Bool = false,
      mentions: [String] = []
    ) -> AppComment {
      AppComment(
        ref: ref, kind: kind, actor: actor, body: "Body of \(ref)\nSecond line",
        createdAt: "2026-11-16T11:00:00.000Z", replyTo: replyTo, deleted: deleted,
        resolvedAt: resolved ? "2026-11-16T11:30:00.000Z" : nil, mentions: mentions)
    }

    @Test func repliesJoinTheirRootInOrder() {
      let content = DiscussionContent(
        comments: [post("AC-9/1"), post("AC-9/2", replyTo: "AC-9/1"), post("AC-9/5")],
        resolved: [post("AC-9/3", resolved: true), post("AC-9/4", replyTo: "AC-9/3")])
      #expect(content.open.map(\.id) == ["AC-9/1", "AC-9/5"])
      #expect(content.open[0].replies.map(\.ref) == ["AC-9/2"])
      #expect(content.resolved.map(\.id) == ["AC-9/3"] && content.resolved[0].resolved)
      #expect(content.count == 3)
      #expect(content.open[0].state == "Open · 1 reply")
      #expect(content.open[1].state == "Open")
      #expect(content.resolved[0].state == "Resolved · 1 reply")
    }

    @Test func repliesFindTheirRootWhateverTheOrder() {
      let threads = DiscussionContent.threads([
        post("AC-9/1"), post("AC-9/5"), post("AC-9/6", replyTo: "AC-9/1"),
      ])
      #expect(threads.map(\.id) == ["AC-9/1", "AC-9/5"])
      #expect(threads[0].replies.map(\.ref) == ["AC-9/6"])
    }

    @Test func aResolvedHandoffInCoresNormalReadGoesWithTheResolved() {
      let content = DiscussionContent(
        comments: [post("AC-9/8", kind: "handoff", resolved: true), post("AC-9/9")], resolved: [])
      #expect(content.open.map(\.id) == ["AC-9/9"])
      #expect(content.resolved.map(\.id) == ["AC-9/8"])
    }

    @Test func deletedRootsTakeNoRepliesAndDeletedRepliesDontCount() {
      let threads = DiscussionContent.threads([
        post("AC-9/1", deleted: true), post("AC-9/2", replyTo: "AC-9/1"),
        post("AC-9/3", replyTo: "AC-9/1", deleted: true),
      ])
      #expect(!threads[0].canReply)
      #expect(threads[0].state == "Open · 1 reply")
      #expect(!DiscussionContent.threads([post("AC-9/4", resolved: true)])[0].canReply)
    }

    @Test func anOpenQuestionToTheHumanIsAnsweredNotRepliedTo() {
      let question = post("AC-12/1", kind: "question", mentions: ["human:acme"])
      #expect(DiscussionContent.threads([question])[0].asks("human:acme"))
      #expect(!DiscussionContent.threads([question])[0].asks("human:other"))
      let answered = DiscussionContent.threads([
        question, post("AC-12/2", "agent:codex:fixture", kind: "answer", replyTo: "AC-12/1"),
      ])
      #expect(!answered[0].asks("human:acme"))
      #expect(!DiscussionContent.threads([post("AC-9/1")])[0].asks("human:acme"))
    }

    @Test func aReplyWithoutItsRootStillShows() {
      let content = DiscussionContent(comments: [post("AC-9/7", replyTo: "AC-9/1")], resolved: [])
      #expect(content.open.map(\.id) == ["AC-9/7"])
    }

    @Test func moreThanTwoRepliesFoldToTheNewest() {
      let replies = (2...5).map { post("AC-9/\($0)", replyTo: "AC-9/1") }
      let thread = DiscussionContent.threads([post("AC-9/1")] + replies)[0]
      #expect(thread.visibleReplies(expanded: false).map(\.ref) == ["AC-9/5"])
      #expect(thread.foldedCount(expanded: false) == 3)
      #expect(thread.visibleReplies(expanded: true).count == 4)
      #expect(thread.foldedCount(expanded: true) == 0)
      let two = DiscussionContent.threads([post("AC-9/1")] + replies.prefix(2))[0]
      #expect(two.foldedCount(expanded: false) == 0)
    }

    @Test func headersNameTheHumanAndWhomAQuestionAsks() {
      let question = post("AC-12/1", kind: "question", mentions: ["human:acme"])
      #expect(
        DiscussionContent.kind(question, isReply: false, human: "human:acme")
          == "question to you")
      #expect(DiscussionContent.name("human:acme", human: "human:acme") == "You")
      let reply = post("AC-9/2", "agent:codex:fixture", replyTo: "AC-9/1")
      #expect(DiscussionContent.kind(reply, isReply: true, human: "human:acme") == "reply")
      let answer = post("AC-14/2", "agent:codex:review", kind: "answer", replyTo: "AC-14/1")
      #expect(DiscussionContent.kind(answer, isReply: true, human: "human:acme") == "answer")
      let thread = DiscussionContent.threads([post("AC-9/3", resolved: true)])[0]
      #expect(DiscussionContent.summary(thread, human: "human:acme") == "Claude: Body of AC-9/3")
    }
  }
#endif
