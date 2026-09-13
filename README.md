# remark.nvim

<img src="assets/logo.svg" alt="remark.nvim" align="right" width="72">

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

`setup()` registers the commands below and redraws comments as you move between
buffers. remark.nvim leaves the diff view to you: pair it with your usual diff
plugin (mini.diff, gitsigns) to see and navigate the changes.

Select the lines a comment concerns and run `:RemarkComment`; with no selection
it comments on the current line.

Commenting, replying, and editing open an editable markdown buffer in a split.
Write it (`:w` or `<C-s>`) to submit, or `q` to cancel; an empty buffer records
nothing.

A thread shows in the code as a bar in the sign column spanning its range, with
a count where more than one thread starts on a row. Resting the cursor on a
thread previews it in a read-only float; `:RemarkOpen` opens it focused and
interactive, disambiguating when several cover the line. Inside that float:
`r` replies, `e` edits and `D` deletes the comment under the cursor (yours only;
theirs is read-only), `z` zooms to near-fullscreen, and `q` closes it.

### Commands

| Command | Acts on |
| --- | --- |
| `:RemarkComment` | The visual selection, or the current line if none |
| `:RemarkOpen` | The thread under the cursor, in an interactive float |
| `:RemarkHover` | The threads on the line, previewed in a read-only float |
| `:RemarkReply` | The thread under the cursor |
| `:RemarkResolve` | The thread under the cursor |
| `:RemarkUnresolve` | The thread under the cursor |
| `:RemarkEdit` | Your latest comment in the thread under the cursor |
| `:RemarkDelete` | Your latest comment in the thread under the cursor |
| `:RemarkList` | Every thread, sent to the quickfix list |
| `:RemarkWipe` | Every thread, deleted; confirms first, `:RemarkWipe!` skips the prompt |
| `:RemarkRefresh` | Replays the log and redraws |

### Mappings

Each action is exposed as a `<Plug>` mapping so you choose your own bindings.
Map with `remap = true` so the `<Plug>` right-hand side expands:

```lua
vim.keymap.set({ "n", "x" }, "<leader>rc", "<Plug>(RemarkComment)", { remap = true })
vim.keymap.set("n", "<leader>ro", "<Plug>(RemarkOpen)", { remap = true })
vim.keymap.set("n", "<leader>rr", "<Plug>(RemarkReply)", { remap = true })
vim.keymap.set("n", "<leader>rx", "<Plug>(RemarkResolve)", { remap = true })
vim.keymap.set("n", "<leader>ru", "<Plug>(RemarkUnresolve)", { remap = true })
vim.keymap.set("n", "<leader>re", "<Plug>(RemarkEdit)", { remap = true })
vim.keymap.set("n", "<leader>rd", "<Plug>(RemarkDelete)", { remap = true })
vim.keymap.set("n", "<leader>rl", "<Plug>(RemarkList)", { remap = true })
```

`<Plug>(RemarkWipe)` deletes every thread. It always confirms first, since the mapping
has no bang form. The example above leaves it unbound; use `:RemarkWipe` instead.

`<Plug>(RemarkComment)` is mapped in both normal and visual mode: in visual mode
it comments on the selection, in normal mode on the current line.

## Pickers

`:RemarkList` sends every thread to the quickfix list, which most pickers can
read. No extra plugin is needed.

To build a custom picker, `require("remark").threads()` returns the raw
threads in log order and leaves the presentation to you. Each thread looks like:

```lua
{
  id = "…",
  file = "/abs/path.lua",
  range = { s = 12, e = 18 },   -- 1-based line span
  commit = "…",                 -- revision the thread anchors to
  status = "unresolved",        -- or "resolved"
  comments = {                  -- oldest first
    { id = "…", source = "local", body = "…", author = "…" },
  },
}
```

Telescope, via a custom finder:

```lua
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values

pickers.new({}, {
  prompt_title = "Remark threads",
  finder = finders.new_table({
    results = require("remark").threads(),
    entry_maker = function(t)
      local body = t.comments[1] and t.comments[1].body or ""
      return {
        value = t,
        display = string.format("%s  %s", t.status, body),
        ordinal = body,
        filename = t.file,
        lnum = t.range.s,
      }
    end,
  }),
  sorter = conf.generic_sorter({}),
  previewer = conf.grep_previewer({}),
}):find()
```

snacks.picker:

```lua
Snacks.picker.pick({
  items = vim.tbl_map(function(t)
    return {
      text = (t.comments[1] and t.comments[1].body) or "",
      file = t.file,
      pos = { t.range.s, 0 },
      thread = t,
    }
  end, require("remark").threads()),
  format = "text",
  confirm = "jump",
})
```

fzf-lua (entries are strings, so encode `file:line:text` and let the builtin
previewer read it):

```lua
require("fzf-lua").fzf_exec(
  vim.tbl_map(function(t)
    local body = t.comments[1] and t.comments[1].body or ""
    return string.format("%s:%d:%s  %s", t.file, t.range.s, t.status, body)
  end, require("remark").threads()),
  { prompt = "Threads> ", previewer = "builtin", actions = require("fzf-lua").defaults.actions.files }
)
```

mini.pick:

```lua
MiniPick.start({
  source = {
    name = "Remark threads",
    items = vim.tbl_map(function(t)
      local body = t.comments[1] and t.comments[1].body or ""
      return {
        text = string.format("%s:%d  %s  %s", t.file, t.range.s, t.status, body),
        path = t.file,
        lnum = t.range.s,
        thread = t,
      }
    end, require("remark").threads()),
  },
})
```

## Limitations

Comments anchor to line ranges rather than following the code across rewrites.
