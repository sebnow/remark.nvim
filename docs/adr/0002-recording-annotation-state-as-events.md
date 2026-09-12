---
status: Accepted
date: 2026-09-12
---

# Recording annotation state as events

## Summary

The canonical store is an append-only log of events, one per repository, replayed into per-thread state rather than edited in place.

## Context

Building on the local store being authoritative (see [owning the canonical store](0001-owning-the-canonical-store.md)), that store has to represent state that changes constantly. Threads open, comments reply to them, threads resolve and reopen, and comments get edited and deleted. How the store records those changes is a separate choice from who owns it, and it sets the terms for concurrency, history, and sync.

Two writers touch the store at once in normal use. The user acts through the editor, and a coding agent posts replies into the same live session. Both need to write without losing each other's work. Sync with an external system also needs to tell what has already crossed the boundary so it does not duplicate on the next pass.

## Decision

The store is an append-only log in newline-delimited JSON, one log per repository. Every change is an event (a thread opened, a comment added, a thread resolved or reopened, a comment edited or deleted), and current state is the projection you get by replaying the log. Writers never edit earlier entries; each change appends a new line.

This decision fixes the shape of the store: an append-only log of typed events. The authoritative schema lives in the code and may gain events or fields without a new ADR. The sketch below only demonstrates the shape:

```json
{"event":"threadOpened","threadId":"t1","commit":"a1b2c3d","file":"lua/review/store.lua","range":[10,14],"time":"2026-09-12T09:00:00Z"}
{"event":"commented","threadId":"t1","commentId":"c1","source":"local","body":"This read races with the writer below.","time":"2026-09-12T09:00:00Z"}
{"event":"commented","threadId":"t1","commentId":"c2","source":"agent","body":"Guarded it with the advisory lock in the latest change.","time":"2026-09-12T09:05:00Z"}
{"event":"resolved","threadId":"t1","source":"local","time":"2026-09-12T09:06:00Z"}
```

Replaying those four lines yields one resolved thread anchored to commit `a1b2c3d`, carrying a local comment followed by an agent reply.

## Options

- **A mutable document of thread objects** (a JSON file rewritten on each change). It is the most direct. Current state is the file itself, with no replay. But two concurrent writers clobber each other on the rewrite, no record survives of how a thread reached its state, and reconciling against an external copy means diffing whole objects with no natural key for what already synced. Rejected.
- **An embedded database** (SQLite). It would provide transactional writes and indexed queries, which cover the concurrency the design needs. The price is a binary dependency and an opaque on-disk format for a single-user, append-heavy workload whose querying stays trivial. Rejected.
- **An append-only event log.** Appends, serialised by an advisory lock, are safe under concurrency, and the full history is kept, which suits two writers and sync de-duplication. The cost is that readers reconstruct state by replay, and the log will need compaction over time. Chosen.

## Consequences

Concurrent writers coexist safely, since each only ever appends and an advisory lock serialises the append itself, and the full history of every thread is retained for audit and for sync to key against. The costs are that readers reconstruct state by replay rather than reading it directly, replay grows with the log, and the log will eventually need compaction, which is deferred rather than solved here.
