---
status: Accepted
date: 2026-09-12
---

# Discovering the running session

## Summary

Each running instance publishes its server address and log path into a registry
file keyed by repo root, so an external agent can find the session to call and the
log to read without hardcoding either.

## Context

The agent posts into a live session over `nvim --server <addr> --remote-expr`
(see [attributing comments to their origin](0003-attributing-comments-to-their-origin.md)
for what it posts), but it has no way to learn `<addr>` on its own: the address is
assigned per instance, at random unless something records it. The agent also needs
the log path to read pending threads. The log lives under the plugin's state
directory, keyed per repo root, and `setup()` can override it, so the path is not a
single constant the agent could hardcode. The registry has to carry it so the agent
reads the path `setup()` resolved.

A session reviews whichever repos the user opens files from, keeping each repo's
threads in that repo's own log. An agent working against one repo needs the session
and log for that repo, so discovery is keyed by repo root rather than a single
global entry.

## Decision

A session registers `{ serverAddr, logPath }` under a repo root in a registry file
under the plugin's state directory the first time it opens that repo's log: on
setup for the repo of the working directory, and later for each other repo the user
opens a file from. It reuses its own server address if one already exists and
starts one otherwise. On exit, it removes each entry that still names its address. A second session registering for the same repo root overwrites the
first; nothing arbitrates between two sessions open on one repo at once. The
registry publishes the log path setup resolved, so a default and a configured
override are carried the same way.

## Options

- **Fixed, well-known path or address.** The agent would need no lookup, but the
  plugin does not control the server address (Neovim assigns it), and the log path
  is not fixed either: it is derived per repo root and can be overridden, so a
  hardcoded path would be wrong for every repo except the one it was configured
  for. Rejected.
- **Environment variable set by the user's shell.** It needs no file on disk, but
  the user would have to export it by hand into every shell that starts the agent.
  Rejected.
- **Per-repo registry file.** Entries are keyed by repo root, the registry
  costs one small file, and it carries the resolved log
  path directly, so the agent never reconstructs it. Chosen.

## Consequences

An agent finds `<addr>` and the log path with one lookup keyed by repo root, and
discovery does not depend on how that path is derived. Running two sessions on the
same repo at once is unsupported: the second overwrites the first's entry, and
nothing arbitrates between them.
