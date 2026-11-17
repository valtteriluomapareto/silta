/// One bounded revision-discussion page for a typed viewer.
package struct DocCommentPage: Sendable {
  package let posts: [CommentDetails]
  package let total: Int
  package let offset: Int
}
