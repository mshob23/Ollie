# VISION — what Ollie is

This is the soul document. The contract says how to build; this file says
what we are building and — just as binding — what we are refusing to build. When a
proposed change is *product-shaped*, check it here first. If it violates a non-goal, either
the proposal is wrong or the vision has genuinely changed; in the second case, change this
file deliberately, in its own commit, before writing code.

## One sentence

Ollie is a **mailbox and a bulletin board**: you drop thoughts in from your wrist, pocket,
or desk the moment they occur, and intelligence you already own posts back what it wants
to show you.

## The shape of the product

Two surfaces, and only two:

- **An avenue in.** Notes — spoken or typed, captured in a breath. Capture never waits on
  intelligence, connectivity, or sync. This is the founding invariant and everything else
  bends around it.
- **A canvas back.** Views — small, living documents an agent publishes: a metric on the
  wrist, a timeline on the phone, a weekly report waiting under a pinned name for later
  reading. The agent decides what is worth showing; the user reads, ticks a checkbox,
  restores a revision — and those interactions flow back to the agent as context.

Everything between the two surfaces is **asynchronous**. You speak into the watch on a
walk; a view lands back on the wrist minutes later. There is no session, no spinner, no
conversation to hold open. Asynchrony is not a limitation to engineer away — it is what
lets the product stay a mailbox instead of becoming a terminal.

## What Ollie is not

- **Not a chat app, an agent runtime, or a Claude Code / OpenClaw replica.** The moment
  Ollie needs a live tunnel to an agent, we are building the wrong product. Information is
  made available; a canvas is offered in return. That is the whole interface. The refusal
  is about *dependence*, not guests: any runtime the user already trusts — a Claude CLI, an
  OpenClaw-style daemon, Siri — is welcome to walk through the same door and speak the same
  file contract (scene 4 below), and Ollie needs zero changes to admit it. What must never
  happen is Ollie *needing* one of them to hold a session open.
- **Not a service.** There is no vendor server, no account, no subscription to us, and no
  copy of the user's data in our custody — ever. The only store is the user's own private
  iCloud database.
- **Not the intelligence.** Ollie validates *mechanics* (ids, sizes, caps) and never
  *meaning* (whether a tag is sensible, whether a memory is true). The thinking is rented
  from whatever agent the user already has — Claude today; Siri, an on-device model, or
  something unnamed tomorrow. Ollie must never care which.

## Who pays for what

The user already pays for a phone, a watch, a laptop, iCloud, and their AI subscriptions.
**Ollie adds zero new bills.** This is a hard constraint, not a pricing strategy: the
moment the architecture requires a server we run or per-token API keys the app holds, the
constraint is violated and the design is wrong. Today's corollary: the only agent runtimes
covered by consumer subscriptions are desktop CLIs — which is why the Mac is where the
intelligence stands (see below), not a compromise we route around.

## The trust model

The clean security line is not "on-device vs. external" — it is **whose custody the data
is in**. The trust domain is: the user's devices + their private iCloud database + agent
runtimes they already trust with their words. Inside that domain, data moves freely.
Crossing it is what requires deliberate design, and there is exactly **one gate**: the Mac
app's export boundary (`~/Ollie/`), where restriction is contagious and enforcement lives.

Structural rules that keep the model honest:

- **One gate.** The app never holds API keys and never egresses data itself. A second
  export path is a second place to get privacy wrong; don't add one.
- **One store writer.** All agent writes queue through the inbox and are validated at
  apply time by the app. A second writer is how the model dies.
- **Notes are immutable ground truth; the agent layer is derived, attributed, and
  disposable.** The user can always burn the intelligence layer down and lose nothing
  they said.
- **The web is read-only, and a query is egress.** The rented agent may *read* the public
  web to serve the corpus; it still writes back only through the inbox. But a search query
  crosses to a third party outside the custody domain, so it is distilled and minimal —
  topic terms, never verbatim note text, never identifiers the request doesn't demand,
  never note content in a URL. (Restricted notes never reach the agent at all, so they
  cannot leak here.)

## The contract is the product

Agents do not integrate with an app or even with the MCP server — they integrate with a
**file contract**: the exported corpus and layer files in, inbox ops out, with every cap
and validation enforced once, at the single writer (`docs/agent-contract.md` is canonical).
The MCP server is a thin *adapter* over that contract, and thin is the point:

- Claude (or any desktop agent) speaks to it via MCP **today**.
- Siri / Apple Intelligence will speak to it via **App Intents** when that matures.
- An on-device model (Foundation Models) could one day run the runbook **inside the app**.

Each future is a new thin adapter, not a new avenue. Nothing learned or built against the
contract is throwaway when the intelligence relocates.

## The Mac is a home node, not a desk

Until phones can run a respectable agent, the always-on Mac stands in for it: notes sync
to it through CloudKit, an agent runs there on schedule or on arrival of new notes, and
views ride CloudKit back out to the phone and the wrist. The user does not need to be at
the desk — they need the Mac to be awake somewhere in their home.

This makes the Mac a **simulator for the on-device future with identical contract
semantics**. Everything we learn iterating now — runbook style, view quality, interaction
loops, memory hygiene — transfers wholesale when the compute moves onto the phone, because
only the *location* of intelligence changes, never the contract. We are not stuck betting
on a future; we are rehearsing it on hardware we already own.

## Time, attention, and memory

Principles for how the system treats the growing corpus:

- **Notes are never deleted; relevance fades by *distillation*, not deletion.** Durable
  content gets promoted into agent memory and views; the raw note then cools out of the
  working window naturally but remains searchable forever. Old thoughts become sediment,
  not garbage.
- **Coverage metadata is advisory, never access control.** "Seen" markers, last-run
  timestamps, and run logs exist to inform the next agent's focus — they must never gate
  what an agent may read.
- **Duplicate work is prevented by idempotence, not bookkeeping.** Tags are set-semantics,
  views append revisions, memory appends and retires. Re-processing a note must always be
  harmless; exactly-once delivery is explicitly a non-goal.

## North-star scenes

The product is right when these are true:

1. On a walk, you speak three thoughts into your watch. Before you're home, a small view
   on your wrist has quietly updated to reflect them.
2. A week of scattered notes becomes a Sunday report, waiting under a pinned name — you
   never asked for it that week; your standing instructions did.
3. You tick a checkbox on the wrist-sized view; the next agent run acknowledges it and the
   view moves on.
4. A new intelligence shows up — Siri, an on-device model, a different vendor's agent —
   reads the standing instructions, reuses the existing tag vocabulary, and publishes to
   the same board. Nothing about Ollie changed to admit it.
