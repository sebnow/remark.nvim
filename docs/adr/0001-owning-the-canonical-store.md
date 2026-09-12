---
status: Accepted
date: 2026-09-12
---

# Owning the canonical store

## Summary

The local store neovim writes is the single source of truth for annotations. Every other holder is an adapter that syncs into and out of it.

## Context

A single comment can exist in more than one system at once. It might originate in the editor session, be mirrored to a coding agent, or map to a thread in an external system like GitHub, so the same comment ends up held in several places. Once two copies exist they can diverge, and something has to be authoritative when they do. Nothing downstream (sync, deduplication, conflict handling) has a defined answer until that authority is named.

The plugin runs inside the editor, where the user reads code and acts on it. The editor is present in every session, it works with no network, and it is where the human makes decisions.

## Decision

The local store that neovim writes is authoritative. Every other place annotations live (a coding agent's view, or an external adapter) is a peripheral copy kept in step by an adapter that syncs in both directions. When an adapter and the local store disagree, the local store wins and sync reconciles the adapter toward it, matching on external identifiers to avoid duplicating what already crossed the boundary.

## Options

- **No canonical store, each source keeps its own.** Its pull is simplicity. Nothing is designated authoritative and no reconciliation code exists. But divergence then has no resolution, and there is no defined way to merge an agent's reply, a thread from another source, and the user's local edits, so the model breaks the moment a second origin appears. Rejected.
- **Make an external system canonical** (for example, a platform such as GitHub). It would hand ownership, durability, and history to a mature system built for it. The price is that the tool stops working offline, couples the core to a single external adapter, and pays a round trip for every local action. Rejected.
- **Make the local store canonical.** It works offline and lets the core own its model, at the cost of the user keeping the store durable and of explicit reconciliation whenever an external copy is synced. Chosen.

## Consequences

The tool works fully offline, and the core owns its data model independently of any adapter. The cost lands on synchronisation. Pushing back to an external system such as GitHub needs explicit reconciliation rather than a naive overwrite, and the local store becomes something the user is responsible for keeping durable, since losing it loses the authoritative copy.
