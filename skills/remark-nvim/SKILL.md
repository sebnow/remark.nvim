---
name: remark-nvim
description: "Read and reply to code-review comments in a live remark.nvim Neovim session. Use when asked to check for reviewer comments, address feedback, reply to a thread, or leave a comment in a repo using remark.nvim."
---

# remark.nvim agent RPC

remark.nvim runs inside the reviewer's Neovim. Call it with
`nvim --server <addr> --remote-expr '<lua>'`.

## Find the session

Sessions register under repo root in a registry file:

```sh
reg="${XDG_STATE_HOME:-$HOME/.local/state}/nvim/remark.nvim/sessions.json"
root=$(jj root 2>/dev/null || git rev-parse --show-toplevel)
addr=$(jq -r --arg r "$root" '.[$r].serverAddr' "$reg")
```

No entry means no live session for this repo; stop here.

## Read comments

```sh
nvim --server "$addr" --remote-expr 'v:lua.require("remark.agent").unresolved_comments()'
```

Returns plain text: each unresolved thread as its `thread_id`, then
`file:line_start-line_end`, then its comments as `<author>: <body>`, with a
blank line between threads.

## Reply or comment

Write the body to a temp file first; it is passed as a path and read as raw
bytes (no escaping). `<name>` is your own identifier, shown as the author.

```sh
# reply to an existing thread
nvim --server "$addr" --remote-expr 'v:lua.require("remark.agent").reply_as_agent("<name>", "<thread_id>", "<body_path>")'
# open a new thread (<file> is an absolute path; line_start/line_end are 1-based, inclusive)
nvim --server "$addr" --remote-expr 'v:lua.require("remark.agent").comment_as_agent("<name>", "<file>", <line_start>, <line_end>, "<body_path>")'
```

Both return JSON: `{"ok":true,"thread_id":"..."}` or `{"ok":false,"error":"..."}`.
