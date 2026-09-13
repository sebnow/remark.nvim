---
status: Accepted
date: 2026-09-13
---

# Writing against a current log

## Summary

A write whose result depends on existing state replays the whole log, decides against that state, and appends only if the log's byte length is unchanged when it commits. Because the log only grows by appending, its length serves as a version, so a concurrent append shows up as a changed length and the write re-evaluates instead of recording a stale decision.

## Context

The store is an append-only log with two writers in normal use, the user through the editor and a coding agent from its own process (see [recording annotation state as events](0002-recording-annotation-state-as-events.md)). That decision serialises the append itself with an advisory lock, which is enough for a write whose correctness does not depend on what is already recorded.

Client-minted identity (see [assigning identity to threads and comments](0009-assigning-identity-to-threads-and-comments.md)) and the overwrite rule (see [overwriting recorded content](0011-overwriting-recorded-content.md)) change that. Recording a comment now depends on current state. A create has to know whether its identifier already exists, and an edit or delete has to know its target is present. The command learns this by replaying the log, and then it appends.

Between the replay and the append, the other writer can append. When it does, the decision rests on a state that no longer holds: a create judged new may now collide, and an edit's target may have moved or been deleted. Appending that decision corrupts state. The advisory lock over the append does not close the window, because the read that informed the decision happened outside it. Holding the lock across the whole sequence is not open to us either, because the decision can require a user confirmation, and the lock would then span human latency while the other writer waits.

## Decision

A state-dependent write replays the whole log to a known state and records the log's byte length as that state's version. It decides against the replayed state, and where [overwriting recorded content](0011-overwriting-recorded-content.md) calls for it, confirms with the user, all without holding the lock. To commit, it takes the advisory lock, reads the log's current byte length, and appends only if that length equals the version it recorded. If the length differs, another writer has appended (or the log was wiped) since the read, so the write releases without appending, replays from the current end, and decides again, which can turn a create into an overwrite or invalidate a target and prompt afresh.

A blind append of a fresh identifier keeps the plain lock-serialised path, since its result does not depend on current state.

The version is the log's byte length because an append-only log grows by whole lines and never rewrites, so its length rises with every committed write. One integer comparison under the lock tells the write whether anything landed since it read.

## Options

- **Serialise the whole read-decide-append under the advisory lock.** It closes the window directly, but the decision can require a user confirmation, so the lock would span the time a prompt sits open and stall the other writer for that whole time. Rejected.
- **Trust the append lock alone**, as a blind append does. Correct for a write whose result does not depend on current state, but a state-dependent write decided outside the lock races the other writer and can append a decision that no longer holds. Rejected for these writes.
- **Check the version on commit**: record the log's length at the read, and under the lock append only if it is unchanged, otherwise re-evaluate. The lock stays short and never spans a prompt, and the price is a re-replay when a write is contended. Chosen.

## Consequences

Two writers work at once without a state-dependent write clobbering the other's, because each confirms the log has not moved before it commits and restarts when it has. A contended write pays for a second replay, and an overwrite whose target changed underneath it prompts again, so the user can be asked twice when two writers touch one thread at the same moment. The version needs no extra storage, since it is the log's length, and takes one comparison to read. A state-dependent write parses the log once to decide and reads its length once to commit, the second being a size check rather than another parse.
