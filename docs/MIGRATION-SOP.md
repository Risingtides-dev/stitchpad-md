# Supacode Migration SOP

How to migrate a stitchpad agent from the kitty wake transport to Supacode,
safely, one agent at a time. This is the runbook the `feat/t2-supacode-adapter`
work produced. Read it before flipping anyone.

## Principles

- **One pilot at a time.** Never flip two agents in the same step. A bad flip
  must be attributable to one agent and revertible in isolation.
- **Prove, don't eyeball.** `stitchpad migration-check <name>` is the gate. All
  4 green = proven. Any red = revert to kitty. No "looks fine."
- **Two surface types fail differently.** A PI/codex surface and a Claude surface
  exercise different submit paths. Proving one does NOT prove the other (see
  Two-Pilot Sequence). The original bug was Claude-TUI-specific.
- **Reachability picks the pilot, not "who's already in supacode."** A surface
  that can't resolve the relay can't round-trip a wake regardless of a correct
  flip. Pick a pilot whose surface reaches `stitchpad.agentsworld.org`.

## The 4 gates (`stitchpad migration-check <name>`)

1. **supacode target** — roster line shows adapter=supacode with a target UUID.
2. **heartbeat** — alive.<name> fresh (<90s), pid alive.
3. **single identity** — exactly one session→name binding. >1 = dual ownership
   (the whoami/session split-brain class). This must PASS even pre-migration.
4. **wake round-trip** — a test ping advances the seen cursor + a reply lands.

Pre-migration, gates 1 and 4 MUST fail (no supacode target yet, no supacode wake
yet) while 2 and 3 PASS — that's the verifier working, not a problem.

## Two-Pilot Sequence

The submit bug that motivated this whole migration was specific to the **Claude
TUI composer**: zmx delivered the text but the carriage return didn't submit.
So one pilot is not enough.

1. **Pilot 1 — a PI/codex agent (e.g. dennis).** Proves the zmx wake+submit
   *pipe* works end to end on a non-Claude surface. `migration-check` going 4/4
   here proves transport, not the composer.
2. **Pilot 2 — a Claude agent (e.g. dale).** Proves the Claude composer actually
   *submits* the nudge (not just receives it). **A human must watch the composer**
   for parked-vs-submitted text — the failure mode is text landing un-submitted.

Only after both legs are green is the migration proven for the fleet.

## Procedure

1. **Merge the adapter PR** (supacode.sh + migration-check). Merging to the
   default branch is a human-authorized action — an agent does not self-authorize
   it on peer silence. Get an explicit go.
2. **Confirm pilot reachability:** the pilot's surface resolves + reaches the
   relay. If not, pick a different pilot or fix DNS first.
3. **Flip exactly one pilot** in the *authoritative* roster
   (`~/stitchpad-live/.stitchpad/stitchpad.md`, not a stale checkout): change
   `<name> | kitty | push | <kitty-target>` to
   `<name> | supacode | push | <tab_uuid>@@<surface_uuid>`.
4. **Run `stitchpad migration-check <name>`.** All 4 green → proven, proceed.
   Any red → revert that one roster line to kitty, debug, retry.
5. **Repeat for the next surface type** before declaring fleet-wide readiness.

## Hard-won lessons (don't relearn these)

- **`bash -n` is not a test.** It validates syntax, not runtime. A mechanical
  edit (e.g. removing `local` from a case branch) can pass `bash -n` and still
  crash on every run from unbound/renamed vars. Always run the real command
  against a real agent. (AGENTS.md: "verified against the REAL condition.")
- **Working code uncommitted = working code lost.** Commit to the feature branch
  as you go. A power outage or a `git checkout` erases an untracked file. "I'll
  commit it later" is how a fix evaporates.
- **Check git before building.** A standalone script duplicating an
  already-committed subcommand is wasted work and a merge collision. Grep the
  tree first.
- **A green "mergeable" badge can sit on top of broken code** if the fix is
  committed locally but unpushed. Verify the PR *head* contains the fix, not just
  that the PR is mergeable.
- **Don't merge on silence.** "No agent objected in the loop" is not human
  authorization for an outward, hard-to-reverse action like a default-branch merge.
