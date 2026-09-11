# remark.nvim

Code review inside Neovim. Read a set of changes and leave comments pinned to the
lines they concern, the way a pull request does, without the code leaving the
editor. You review in the buffers you edit in, with the LSP, motions, and
navigation available.

## Features

- Works the same over git and jujutsu.
- Comment on one line or a range, pinned to those lines.
- Thread replies onto comments, each marked resolved or unresolved.
- Let a coding agent reply in the same threads.
- Anchor each comment to the commit it was made against, and mark it outdated once
  later commits touch the lines it covers.

## Setup

Install with your plugin manager, then enable it:

```lua
require("remark").setup()
```

Select the lines a comment concerns and run `:RemarkComment`. remark.nvim leaves
the diff view to you: pair it with your usual diff plugin (mini.diff, gitsigns) to
see and navigate the changes.

## Limitations

Comments anchor to line ranges rather than following the code across rewrites.
