---
status: Accepted
date: 2026-09-12
---

# Attributing comments to their origin

## Summary

A comment stores its origin in a plain field that distinguishes the user from a coding agent.

## Context

By enabling a coding agent to leave comments, the store holds comments from two origins. The user acts in the editor, and the agent posts from its own process. The core has to tell them apart, to label each comment in the interface and to decide who may resolve a thread. The open question is how to represent that origin.

## Decision

A comment records its origin in a plain field on its event in the log (see [recording annotation state as events](0002-recording-annotation-state-as-events.md)). The field is a label for the source, `local` for the user and `agent` for a coding agent, with an optional name by which an agent identifies itself. The core reads the label alone, so it stays independent of any one tool. The name is metadata for display. A reply from an agent that names itself looks like:

```json
{
  "event": "commented",
  "source": "agent",
  "author": "claude",
  "body": "Guarded it with the advisory lock."
}
```

## Options

- **Hard-code the agent into the core**, through an agent-specific reply path or an `isAgent` flag. The core still has to separate user from agent for attribution and permissions, so it saves no step over a field. It adds a special-case path and ties the core to a specific tool. Rejected.
- **Record origin in a plain field.** It costs one value per origin, with no special path and no tool named. Chosen.

## Consequences

The core attributes every comment and can apply rules that depend on origin, and it stays independent of any particular agent.
