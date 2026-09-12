---
status: Accepted
date: 2026-09-12
---

# Dividing the review surface from the diff view

## Summary

The plugin builds only the comment layer and leaves the diff view (signs, hunk navigation, range selection) to the user's own diff plugin.

## Context

A review surface has two halves, a way to see and move through the changes and a way to comment on them. The first half already exists in the neovim ecosystem. Plugins like mini.diff and gitsigns render change signs, navigate hunks, and mark ranges, and they are mature and widely used. The comment layer (threads pinned to lines, replies, resolution, an agent participating) is the part those plugins do not provide.

## Decision

The plugin owns the comment layer and nothing of the diff view. The sign column, hunk navigation, and change display come from whatever diff plugin the user already runs. Comments anchor to the commit at capture time, not to a range selected from a diff the plugin renders, so the tool never needs to draw or drive the diff itself.

## Options

- **Build the whole surface, diff view included.** It would give one integrated experience the user installs on its own, with no dependency on another plugin. But it duplicates mature plugins, inflates the tool's scope. Rejected.
- **Wrap a diff plugin behind a facade** so the plugin drives it as a pluggable source. It would keep the diff under the tool's control while reusing existing plugins. The cost is a diff abstraction the tool does not need once comments anchor to a commit rather than to a live in-editor diff range. Rejected.
- **Own the comment layer only.** It keeps the scope small and composes with whatever diff plugin the user runs, at the cost of depending on the user having one, since the tool then provides no signs or navigation of its own. Chosen.

## Consequences

The scope stays small and the tool composes with the user's existing diff plugin. In exchange the plugin depends on the user having a diff plugin for signs and navigation, since it provides none, and it cannot assume any particular diff UI is present or drive one if it is.
