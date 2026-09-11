# remark.nvim

Code review inside Neovim. Read a set of changes and leave comments pinned to the
lines they concern, the way a pull request does, without the code leaving the
editor. You review in the buffers you edit in, with the LSP, motions, and
navigation available.

## Features

- Review a range of changes (uncommitted work, a span of commits, or a branch
  against where it forked), switchable at any time.
- Works the same over git and jujutsu.
- Comment on one line or a range, pinned to those lines.
- Thread replies onto comments, each marked resolved or unresolved.
- Let a coding agent reply in the same threads.
- Mark a comment outdated once later changes touch the lines it covers.

## Limitations

Comments anchor to line ranges rather than following the code across rewrites.
