---
status: Accepted
date: 2026-09-13
---

# Assigning identity to threads and comments

## Summary

Threads and comments are identified by a UUIDv7 from a shared generator. The client that originates the entity mints the identifier and passes it to the store, which records it. The store does not mint.

## Context

Every thread and comment on the append-only log (see [recording annotation state as events](0002-recording-annotation-state-as-events.md)) carries an identifier. Before this decision, the store minted those identifiers itself, at the moment it appended the event. Under that arrangement, only the store named entities, and only after the event was durably written.

Two problems motivate a change.

A comment is composed before it is stored. The user writes in a draft buffer, and the draft has no identity of its own until it is submitted and the store hands one back. Anything that wants to name, reference, or optimistically display the draft before it lands has nothing to key on.

Appends are not guaranteed to happen exactly once. A crash between forming the intent and the durable write, or a sync pass that re-delivers an event, can present the same logical change twice. When the store mints the identifier, a retry mints a *new* one, so the retry is a distinct entity rather than the same one written again. Nothing identifies the two events as the same logical change.

Both writers in normal use, the user and the agent, create entities independently and must be able to name them without coordinating.

## Decision

Identity for threads and comments is a UUIDv7 produced by a single generator, lifted out of the store into a shared module its callers use. The client that originates an entity mints the identifier before the store records the event and passes it in; both the editor path and the agent path mint their own. The store records the identifier it is given rather than creating one. A thread and its opening comment are written in a single append, both identifiers supplied by the client.

This decision depends on writes being made against a current log (see [writing against a current log](0010-writing-against-a-current-log.md)) and on how a reused identifier is resolved (see [overwriting recorded content](0011-overwriting-recorded-content.md)). A reused identifier is recognised when the write is recorded and turned into a no-op or a confirmed edit.

## Options

- **The store mints exclusively** (status quo). One owner of identity, nothing to pass. But a draft has no name before it is stored, and a retried append is a fresh entity rather than the same one, so at-least-once delivery duplicates. Rejected.
- **The client may mint, the store mints as fallback.** An optional identifier keeps a convenient default and spares callers a change. But every caller is ours and can pass an identifier, so the default buys nothing and leaves identity with two possible origins to reason about. Rejected.
- **The client mints, the store records what it is given.** The store's interface is internal, so requiring an identifier changes only callers we own. Identity has a single origin, the shared generator the client calls, and the store's job narrows to recording. The cost is that every create path must mint. Chosen.

## Consequences

A draft can hold its final identifier before it is written, so the interface can name and reference it and, later, render it optimistically. A caller that reuses an identifier on a retry does not create a duplicate, because the write replays first and recognises the identifier before anything is appended (see [writing against a current log](0010-writing-against-a-current-log.md)). A UUIDv7 embeds the time it was minted, so a client identifier minted when a draft opens carries the draft's open time, not the append time; ordering is unaffected because replay orders by position in the log, not by identifier, but the embedded timestamp now means "when minted," not "when written."
