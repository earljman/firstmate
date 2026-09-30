---
name: decisions
description: >-
  Walk through recorded open captain calls one at a time with the context needed to answer, or present them on the existing Lavish board.
  Use when the captain invokes /decisions, asks to go through open decisions or questions one by one with full context, or asks for the next decision during that walkthrough.
user-invocable: true
metadata:
  internal: true
---

# Decisions

Present and record answers to existing captain calls; never dispatch, merge, tear down, or steer from this skill.
Hand resulting work back to the ordinary lifecycle after recording the answer.
Load [captain-hold-lifecycle](../captain-hold-lifecycle/SKILL.md), which owns decision identity, authoritative-home ownership, and answer semantics.
This skill owns only the walkthrough and its session-local ordinal mapping.

## Gather and number

On every invocation, gather `bin/fm-bearings-snapshot.sh --json --all-decisions --fields bodies,paths` and read its coverage disclosures.
Use only its `decisions_open` captain calls and `bin/fm-captain-hold.sh` to establish the decision inventory; never discover extra decisions by scraping conversation, reports, or status logs.
Read reports explicitly referenced by those calls to explain their evidence, not to expand the inventory.
The snapshot and captain-hold script headers own their fields, bounds, command syntax, and return semantics.

For each available call, retain its owner, task key, and current `open --identity` result from its authoritative home.
The snapshot's owner-qualified display id is not a task key to pass to the command.
Sort initially by the hold-set timestamp returned in that identity, oldest first, breaking ties by owner and task key.
Place unknown dates last and disclose unavailable context or ownership rather than guessing a timestamp or addressing a same-named task in the main home.
If the authoritative home cannot be accessed through its established supported path, present the available facts and hand recording back to its ordinary owner lifecycle without claiming success.

Plain `/decisions` lists each call in one line numbered 1..n, then immediately expands decision 1.
Maintain these numbers for the current walkthrough only: reconcile the mapping against each fresh snapshot, retain numbers for surviving identities, mark removed numbers unavailable, and append newly discovered calls rather than renumbering a previously presented question underneath an answer.
Re-derive current membership and identity on every invocation; do not persist a second decision registry.
A new plain `/decisions` starts a newly numbered list, oldest first.
After a context reset with no reliable mapping, show the fresh list before accepting an ordinal-dependent answer.

## Present one complete question

Each expanded decision must stand alone without requiring earlier chat:

- State the originating ask and who raised it, distinguishing recorded facts from missing provenance.
- Read the referenced evidence or report and summarize its substantive findings, including its path and any uncertainty that affects the choice.
- Explain the available options, each with concrete outcomes, cost or effort, and reversibility; label unknown costs instead of inventing estimates.
- Recommend an option and explain why its consequences fit the originating ask.
- End with exactly what the captain can say to answer, including any parameters needed to make the answer actionable.

If the bounded snapshot or referenced report lacks essential context, say what is missing and do not present a guess as a fully supported recommendation.
Keep multiple questions on one task together and make clear whether the requested answer covers all of them.
Follow `AGENTS.md` section 9: describe outcomes in plain language, use full PR URLs, and never expose internal hold or gate vocabulary in captain-facing prose.
Offer `/decisions lavish` as the visual alternative without requiring it for chat review.

## Navigate and record

- `/decisions next` or “next decision please” presents the next still-open, unvisited call in the current order without changing the previous call.
- `/decisions <n>` expands that number after refreshing and verifying its mapped identity; an unavailable number never silently selects another task.
- `/decisions later <date>` records the captain's explicit deferral answer through [captain-hold-lifecycle](../captain-hold-lifecycle/SKILL.md).
- `/decisions skip` advances to the next still-open, unvisited call for this session only, without changing any durable record.

When the captain answers, bind the reply to the last expanded call, or to the explicitly named ordinal, and recheck its membership and identity before writing.
If the call changed, was answered elsewhere, or the reply does not identify a choice clearly enough, explain the change or ask the narrow clarification instead of applying the words to another question.
Write the captain's exact answer into a decision file and run `bin/fm-captain-hold.sh answer <id> --decision-file <path>` with `--release` when it is a work item awaiting permission to proceed, following the lifecycle owner's distinction.
Do not convert a recommendation, “next”, “skip”, or an incomplete answer into approval.
After successful recording, briefly acknowledge the outcome and automatically present the next unvisited call from refreshed state.
On failure, retain the current question and report the recording problem without claiming the answer took effect.
When the pass ends, distinguish calls reviewed or skipped, calls explicitly deferred, and calls resolved by an answer; unresolved calls remain open.

## Lavish mode

For `/decisions lavish`, compose the same full context for every available call and use `bin/fm-bearings-board.sh build <data.json>` with its existing `fm-bearings-board.v1` payload contract.
Follow [Bearings' Lavish board mode](../bearings/SKILL.md#lavish-board-mode) for card identity, subject hygiene, close mode, and board build rules; the script header remains the owner of all mechanics.
Use decision cards keyed by task id, not merge-action cards or dispatch controls, so this surface records choices and leaves subsequent work to the ordinary lifecycle.
Put the originating ask and evidence summary in `about` and `detail`, the precise question in `decide`, consequences, cost, and reversibility in option hints, and the recommendation reason in `detail` alongside `recommend_value`.
Include the report path and full PR URL where relevant, and allow freeform answers with a hint explaining required parameters.
Keep `underway`, `landed`, and `charted` empty or minimal; retain any landed evidence needed for subject hygiene and any coverage warnings needed to avoid a false all-clear.
The existing payload accepts empty arrays, so no separate board renderer, payload schema, listener, or polling loop is needed.
This rebuild replaces the shared Bearings board at its stable path; tell the captain that the board now shows the decision review and return the verified session URL.

Answers use [Bearings' Handling a board wake](../bearings/SKILL.md#handling-a-board-wake), including its existing limitations for secondmate-owned calls, rather than a second answer handler.
Leave downstream actions to that ordinary lifecycle and rebuild a decision-focused view from fresh state when continuing this walkthrough.

## Empty and incomplete coverage

Apply [Bearings' chat-response coverage rule](../bearings/SKILL.md#chat-response-contract) to any empty-state claim.
Only say nothing is waiting on the captain when the decision set is empty and coverage proves the all-clear.
Otherwise say no decision is recorded in the checked coverage, give the available checked/known counts, and identify missing or truncated coverage.
Do not mistake the end of the current walkthrough for an empty decision inventory.
