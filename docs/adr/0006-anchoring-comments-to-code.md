---
status: Accepted
date: 2026-09-12
---

# Anchoring comments to code

## Summary

A comment is pinned to the commit it was made against plus a file and line range, and it is marked outdated once a later commit changes the lines it covers, with the user clearing stale comments by hand.

## Context

A comment concerns specific lines, and those lines move as the code changes. The store needs a way to say what a comment points at and when that target no longer matches reality. The hard version of this is following the code across rewrites so a comment tracks its lines wherever they go. That is valuable but costly and error-prone.

A comment made against one state of the code should be marked once the code underneath it changes.

## Decision

Each comment records the commit it was made against, whether git `HEAD` or the jujutsu working-copy commit at capture, together with the file and line range it covers. A comment is outdated when a commit made after its anchor changed the lines it covers, which the VCS reports by comparing the anchor commit against the current state for that range. Detection is at line granularity. A change confined elsewhere in the file leaves the comment current. Outdated comments are not re-anchored automatically. The user resolves them explicitly.

## Options

- **Follow-the-code tracking.** It is the most faithful. A comment would move with its lines across rewrites and rarely go stale wrongly. But re-diffing and mapping anchors across rewrites is complex and easy to get subtly wrong. Deferred.
- **Live detection against the editor buffer**, diffing the buffer's current text against its state at comment time as edits happen. Its draw is immediacy. A comment could flag the moment its lines are touched, before the change is saved or committed, which the VCS cannot see because nothing has reached disk. The cost is that the tool maintains its own diff of buffer state, the diff machinery this design delegates rather than builds (see [dividing the review surface from the diff view](0005-dividing-the-review-surface-from-the-diff-view.md)), and it reacts to edits that may be undone or never land in a commit. Rejected.
- **Commit anchor with change detection from the VCS.** It is cheap and predictable and needs no diff engine of its own, since both git and jujutsu can report whether commits after the anchor touched a given line range. The cost is that a comment whose lines moved goes stale rather than following them. Chosen.

## Consequences

Anchoring stays cheap and predictable, and outdatedness falls out of what both git and jujutsu already report, with no diff engine in the plugin. The cost is manual upkeep. A comment whose lines moved goes stale rather than following them, and clearing stale comments is the user's job. Detection also has a blind spot. A comment can be invalidated when its own lines are untouched but the surrounding code changes what they mean, and comparing only the commented range will not catch that. Recognising this context-driven staleness is a harder problem the decision does not tackle.
