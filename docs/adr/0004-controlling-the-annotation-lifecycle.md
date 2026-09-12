---
status: Accepted
date: 2026-09-12
---

# Controlling the annotation lifecycle

## Summary

A thread's resolution state belongs to the user alone. The write path refuses a resolve, reopen, or reset event from an adapter.

## Context

Once the store records comments from more than one origin (see [attributing comments to their origin](0003-attributing-comments-to-their-origin.md)) and one of them is an autonomous agent, the question is who may drive a thread through its lifecycle (resolve it, reopen it, reset it) as opposed to merely commenting in it. Resolution is a judgement about whether the concern is actually addressed, and that judgement is the reviewer's to make. An agent resolving a thread on its own reply would make a decision that belongs to the reviewer.

Because state is a log of typed events (see [recording annotation state as events](0002-recording-annotation-state-as-events.md)), the write path can accept or refuse a change by its event type and the source behind it.

## Decision

The events that move a thread's resolution state (resolve, reopen, reset) may be written only by the user. Writes enter the store through one path, and that path refuses those events from any other source, so an adapter, the agent included, can add comments but cannot get a resolution change in. The rule holds at the write path, not in the log, which on its own would accept any event appended to it. It reaches only the resolution transitions. Commenting is untouched, and who may open a thread is a separate question this decision leaves alone.

## Options

- **Trust every source by convention.** It needs no enforcement code and keeps the writer path uniform. But nothing then stops an agent from emitting a resolve event and closing threads on its own. Rejected.
- **Refuse resolution events from adapters at the write path.** It costs a check at the single point writes enter the store, keyed on event type and source. In return the write path rejects an agent's resolve events. Chosen.

## Consequences

The rule is enforced where writes enter the store. The write path rejects an agent's attempt to close a thread, so review outcomes stay with the reviewer. The trade-off is that resolution is manual by design, with no auto-resolve when an agent believes it has addressed a comment, and every write passes a source check.
