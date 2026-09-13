---
status: Accepted
date: 2026-09-13
---

# Overwriting recorded content

## Summary

A creation whose identifier already exists is resolved when it is written, not when it is replayed. Identical content is a no-op, and differing content becomes a user-confirmed edit. Recorded content is not overwritten without the user's confirmation.

## Context

With client-minted identifiers (see [assigning identity to threads and comments](0009-assigning-identity-to-threads-and-comments.md)), a create can carry an identifier that is already on the log. It happens when a draft that was assigned an identifier is submitted more than once. Appending a second creation for one identifier leaves the log with two origins for one entity: ambiguous, and at risk of losing content.

So a create that finds its identifier already recorded has to be resolved rather than appended as-is. The resolution can depend on the user, since overwriting content someone wrote is theirs to decide, and replay runs headless. It therefore belongs where the change is recorded, while the user is present, against a current view of the log (see [writing against a current log](0010-writing-against-a-current-log.md)).

## Decision

The command that records a creation consults the projection it already holds for the identifier. When the identifier is absent, it appends the creation. When the identifier is present with identical content, it does nothing, because the write is a retry and the log already holds the entity. When the identifier is present with differing content, the write is an overwrite: the command asks the user to confirm, and on confirmation records a `commentEdited` event rather than a second creation.

If another writer appended since the replay, the write re-evaluates before it commits (see [writing against a current log](0010-writing-against-a-current-log.md)).

## Options

- **Leave it to replay**, resolving a duplicate identifier in the projection by keeping the first or the last write. It is deterministic and needs no write-time logic, but it either drops the new content or clobbers the old without the user's knowledge, and replay cannot involve the user in either case. Rejected.
- **Reject a write whose identifier already exists.** It prevents silent loss, but it leaves the user holding an intended change with no way to apply it, forcing a delete and recreate to say what an edit would have said. Rejected.
- **Resolve when the change is recorded**: no-op on identical content, user-confirmed edit on differing content. The user sees the overwrite and confirms it, and the log records the change as an edit. The cost is a projection lookup before a creation and a confirmation step on the overwrite path. Chosen.

## Consequences

An overwrite of recorded content is explicit and auditable, appearing in the log as a `commentEdited` event rather than a creation that replaced another. A creation event records origination; a later change is recorded as an edit. Re-submitting an unchanged draft is harmless, since identical content is a no-op.
