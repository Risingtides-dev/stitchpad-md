# stitchpad one-command installer spec

Target: `stitchpad install [--bridge]` goes from a fresh clone to a working
multi-agent stitchpad with zero hand-editing.

## Principles

- **Idempotent**: re-running the installer must be a no-op if state is already correct.
- **Partial-install safe**: every phase re-checks desired state; no phase is skipped purely because a state file says it ran.
- **Evidence, not authority**: `~/.stitchpad/.installer-state/phase` records the last successful phase for diagnostics/resume UX only.
- **Runtime detection**: only wire configurations for runtimes that are actually present (claude, codex, pi).
- **Verify before claim**: the installer ends with a real wake smoke test, not just `stitchpad doctor`.

## Phase order

1. **deps** — verify `git`, `bash`, `awk`, `python3`, `node` are present. Warn if `fswatch` is missing (optional watcher dependency). Exit non-zero if any required dep is missing.
2. **home** — symlink `~/.stitchpad` → `<repo>/tool`, ensure `~/.stitchpad/bin` is on `PATH` (append to `~/.zshrc` idempotently by pattern match).
3. **runtime detection** — detect which of claude/codex/pi are present by checking command/config dir existence.
4. **hook wiring** — idempotently merge:
   - Claude + Codex Stop hook → `adapters/stop-hook.sh`
   - Claude PreToolUse claim hook → claim shim for `Write`/`Edit` tools (security-reviewed block)
5. **MCP registration** — idempotently register the stitchpad MCP server for detected runtimes:
   - Claude: `~/.claude.json` `mcpServers.stitchpad`
   - Codex: `~/.codex/config.toml` `[mcp_servers.stitchpad]`
   - Pi: `pi install ~/.stitchpad/adapters/stitchpad`
6. **verifier** — prove the installed path works:
   - create a temp pad
   - join a synthetic identity
   - post a self-mention
   - assert `stitchpad wake --peek` returns it
   - run `stitchpad doctor`
   - assert PreToolUse hook is present in Claude settings (when Claude detected)
   - cleanup: `stitchpad leave <synthetic>`, `stitchpad daemon stop`, then `rm -rf` temp dir
7. **optional bridge/PWA** — only with `--bridge`:
   - generate pad-scoped relay token
   - write token to `~/.stitchpad/.state/relay-token` (mode 0600)
   - install launchd login service for `bridge.sh`
   - (PWA deploy: requires Randy's Cloudflare deploy decision)

## Idempotency rules

- Symlinks: skip if the link already points at the correct target.
- JSON/TOML merge: read config, check if the stitchpad entry exists with the expected value, write only if missing or changed.
- MCP `claude mcp add`: use `--force` or the python3 merge pattern; never duplicate entries.
- `pi install`: pi handles idempotency; log success/warning.
- State dir: create `~/.stitchpad/.installer-state/` with mode 0700; write `phase` only after a phase succeeds.

## Partial-install recovery

- Re-running the installer re-checks every phase; nothing is skipped based on the state file.
- If a phase fails, print `installer failed at phase N: <reason>` and exit non-zero. Attach `stitchpad doctor` output if available.
- `--reset` flag removes `~/.stitchpad/.installer-state/` and reruns from phase 1.

## Secrets

- Relay token is generated only in phase 7 and written to `~/.stitchpad/.state/relay-token` with mode 0600.
- Token is passed to the bridge via a user-owned launchd `EnvironmentVariables` entry; never committed.
- `~/.stitchpad/.installer-state/` must be mode 0700.

## Owner lanes

- @ernie: installer script implementation
- @dennis: this spec + phase order/idempotency review
- @mark: PreToolUse shim block + verifier smoke-test shape
- @larry: per-runtime adapter install + post-install wake verification acceptance
- @Jill: README quickstart + clean-machine test + role docs
- @dale: zero-to-running UX + success message
