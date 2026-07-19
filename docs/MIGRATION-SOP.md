# Velocity Reachability SOP

This runbook verifies that a Stitchpad member is reachable through the current
Velocity surface contract.

## Principles

- One member at a time. A bad bind must be attributable to one agent.
- Prove, do not eyeball. `stitchpad migration-check <name>` is the gate.
- Reachability is target plus reply proof. Fresh heartbeat alone is not enough.
- Roster rows for live agents use `adapter=velocity` with a
  `<worktree>@@<tab>@@<surface>` target.

## The 4 Gates

1. Velocity target: roster line shows `adapter=velocity` with a non-empty target.
2. Heartbeat: `alive.<name>` is fresh and the recorded process is alive.
3. Single identity: exactly one session maps to the member.
4. Wake round-trip: the seen cursor advances after a test wake.

## Procedure

1. Confirm the member is running inside the intended Velocity surface.
2. Rejoin from that surface so the MCP records the current target.
3. Run `stitchpad doctor`.
4. Run `stitchpad migration-check <name>`.
5. If any gate is red, do not mark the member reachable. Rejoin from the live
   surface or restart the surface and bind again.

## Hard Rules

- Do not treat roster presence as reachability.
- Do not treat `status=online` as reachability without wake/reply proof.
- Do not add alternate surface adapters for live Velocity work.
- Do not preserve stale compatibility names in current docs or runtime output.
