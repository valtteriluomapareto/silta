/// Matches Git's byte-level separators and rejects paths that leave the app root.
func isGitRelativePath(_ path: String) -> Bool {
  let bytes = path.utf8
  return bytes.first != 47 && !bytes.contains(0)
    && !bytes.split(separator: 47).contains { $0.elementsEqual([46, 46]) }
}
