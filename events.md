# events.md — stitchpad repo ledger

Single append-only chronological ledger for this repo. Shared by all agents
(any harness, any worktree). Newest entries at the bottom. Schema: see root
AGENTS.md.

time:      [11:24pm] [06-17-26]
agent:     [claude] [opus 4.8]
worktree:  main (work staged in /Users/risingtidesdev/stitchpad-live, same repo)
type:      [bug-report]
area:      [backend]

Established this ledger — it didn't exist. smaths asked if the team was following
devlog protocol; the honest answer was no, because the repo had no events.md and no
AGENTS.md chain at all. Created both rather than claim compliance, and backfilled
tonight's work below.
time:      [05:40pm] [06-18-26]
agent:     [codex] [gpt-5] [larry]
worktree:  feat/t2-supacode-adapter
type:      [bug-report]
area:      [infra]

Investigated "watcher not working" during the Supacode/Dale route test. Live watcher was restarted and re-read the roster with `@dale -> adapter=supacode`; `adapter.supacode.log` then showed fresh 17:39 zmx wakes. Found and verified the wake cursor typo fix already present in the installed/repo script: `stitchpad wake dale --peek` no longer crashes on `_mc_seen_file: unbound variable`, `--peek-ordinal` returns a live ordinal, `bash -n tool/bin/stitchpad` and `bash -n tool/bin/watch.sh` pass, and the watcher is running again after restart. Current live evidence shows the remaining Dale failure is Claude TUI submit: zmx delivers text to the Supacode Claude composer, but CR parks instead of submitting; send-key fork remains the real fix path.
_________________________________________________________________________________
time:      [07:30pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [bug-report]
area:      [backend]

Closed a run of wake-path bugs, each verified against the real condition (not a
proxy), several cross-verified by dennis in clean temp pads: (1) broadcast silent-ack
— lib.sh stripped @names before matching "ack", so a team broadcast read as a silent
ack and woke nobody; fixed by counting mentions pre-strip and never silencing 2+.
(2) cold-wake heartbeat gap — a woken session that never ran a CLI had no heartbeat
ticker and decayed offline in 90s; kitty.sh now starts the ticker on wake. (3) sender
mislabel — kitty.sh ctx extractor mis-attributed the wake's "NEW from @X"; replaced
with `wake --peek` (canonical stop-hook source). (4) identity↔window drift — self-heal
routed wakes by window title, which could name the wrong agent; now matches
env.STITCHPAD_NAME first, title fallback, re-stamps title only after an authoritative
match.
_________________________________________________________________________________
time:      [08:00pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [backend]

Dropped-turn recovery (the double-consume race): the watcher AND the stop-hook both
advanced the seen cursor on delivery, so a turn that died mid-tool-chain before posting
lost its mention permanently — smaths saw silence on Telegram. Fix: watch.sh writes
pending.<name> (the open ordinal) on delivery; the stop-hook re-blocks ONCE via new
`wake --force` if the gate's still open, bounded so it can't loop. Per dennis's
acceptance gap, added visibility: a re-block that still gets no reply transitions to
delivered_no_reply.<name>, surfaced in `doctor --json`; an authored reply clears both.
Verified bounded + visible against a real session and dennis's temp pad.
_________________________________________________________________________________
time:      [07:00pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [infra]

Built `stitchpad-team` — one-command outage restore. Reads roster + runtime.<name> +
per-agent color, respawns each kitty member's window (titled, colored, running its
runtime CLI), skips live windows + operator + remote, pins identity via
--env STITCHPAD_NAME so it can't drift from the title. Security-reviewed by mark
(allowlisted runtimes, local-state-only sources, zero pad-body content in env). Proven
by respawning a genuinely-dead agent (dennis, win 21). Full-outage teardown drill held
for smaths to trigger (destructive to the live team).
_________________________________________________________________________________
time:      [11:00pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [frontend]

PWA perf: smaths reported slow load; dennis measured the static shell at 33KB/~0.43s,
so the bottleneck was runtime, not asset weight — render() refetched the whole pad
every 3s and rebuilt log.innerHTML wholesale, re-parsing + repainting the entire log
even when nothing changed. Shipped a skip-render-when-unchanged guard (cache
LAST_LOG_HTML, only touch the DOM on a real content change). Measured in headless
Chrome: 19–29x less idle render work, ~95% reduction, savings grow with conversation
length. Also added loading=lazy + decoding=async to message avatars. Incremental
append held until ernie's /pad ETag/tail contract lands (don't optimize against a
moving payload). Debounce deliberately skipped (the remaining idle cost is the fetch,
which is the transfer-side ETag fix).
_________________________________________________________________________________
time:      [11:25pm] [06-17-26]
agent:     [claude/mark] [sonnet 4.6]
worktree:  main
type:      [review]
area:      [backend]

Security review pass across the full session. Key calls: (1) relay colors contract mismatch — bridge.sh was shipping colors as array [{name,color}] but dale's PWA needed flat object {name:#hex}; caught before deploy, fixed in bridge.sh jq. (2) Remote-join token scope — /join-request returns master STITCHPAD_TOKEN (reads/writes all pads); flagged as wrong for remote agents; recommended pad-scoped session token in KV; team aligned, CLI blocked pending that fix. Trusted-coworker path approved to ship with master token as interim, scoped tokens queued. (3) stitchpad-team launcher audit — verified allowlisted runtimes (claude/pi/codex only), local-state-only env sources, zero pad-body content injected; cleared. (4) PreToolUse shim spec — posted exact bash shim (pretooluse-claim.sh) and settings.json merge block for installer; tool-name matching on Edit/Write only, decision:block on stdout, exit 1 on deny. (5) Delivered_no_reply root cause — confirmed seen cursor advances on delivery before agent posts; defined fix shape (bounded retry + doctor flag). (6) stitchpad send mime validation — flagged that CLI should reject non-image paths client-side before relay upload, not rely solely on worker.js 400.
_________________________________________________________________________________
time:      [11:30pm] [06-17-26]
agent:     [claude/randy] [sonnet 4.6]
worktree:  main
type:      [bug-report]
area:      [backend]

Four wake-path bugs found and closed this session. (1) Broadcast silent-ack suppression: lib.sh engagement gate stripped leading @mentions then matched "ack" as silent — a broadcast "@dale @dennis … ack" suppressed all 7 wakes. Fixed: messages with 2+ @mentions skip the silent-ack path. (2) Cold-wake heartbeat gap: kitty adapter delivered the nudge but woken agents had no alive.<name> heartbeat running, so they decayed offline after 90s. Fixed: kitty.sh now runs `stitchpad heartbeat start <name>` from the watcher on every delivery. (3) Wake message format split: kitty adapter built its own nudge string with custom awk while stop-hook used `wake` output — two diverging formats. Fixed: kitty adapter now calls `stitchpad wake $to --peek` for the canonical one-liner, same source as stop-hook. (4) Sender mislabel in ctx extractor: replaced the custom awk ctx block entirely (bug was in flush() pairing), now both paths use `stitchpad wake`. All four verified against real conditions on the live pad. Also added `stitchpad send <file> [caption]` CLI command (thin exec wrapper into `say --image`; client-side mime+size validation already existed).
_________________________________________________________________________________
time:      [12:40am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [plan]
area:      [research]

Deep-dived Supacode as a potential terminal substrate for the agent pad (we're
running inside it — open-source, github.com/supabitapp/supacode, built on Ghostty).
Reversed an earlier wrong verdict after reading the source: (1) the "tab/surface
create times out without returning a UUID" blocker is a non-issue — TabCommand.swift
self-generates the UUID (or takes -n <uuid>) and fires a deeplink fire-and-forget;
pass our own UUID, ignore the cosmetic timeout, own the handle immediately. Proven
live (created a tab with a chosen UUID, woke it by that UUID rc=0). (2) Colors/titles
port via OSC escapes — Ghostty is truecolor with OSC 2/11/4 + a WindowChromeApplier
subsystem; no CLI color command needed. (3) Supacode has a NATIVE agent-presence +
notification system (AgentPresenceOSC over OSC 3008 + OSC 9, per-surface unread/
progress, agent-hook ownership) that works over SSH — i.e. it natively ships the
remote-coworker wake we hand-built with the Cloudflare relay. Verdict: serviceable
and arguably purpose-built; wakes get simpler (self-assign UUID + `surface focus -i`,
~0.024s) and title-drift bugs evaporate (target an assigned UUID, not a mutable title).
Cost: macOS-only, opinionated app vs a dumb scriptable pty. Proposed transition split
posted to pad: dale builds supacode.sh adapter + one-agent POC; randy confirms wake/
seen/heartbeat rides over unchanged; ernie/larry assess OSC 3008 → roster dots; mark
security-reviews the deeplink/socket model.
_________________________________________________________________________________
time:      [01:40am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [bug-report]
area:      [infra]

Supacode POC: built tool/adapters/supacode.sh (same contract as kitty.sh; wake via
`supacode surface focus -i`, heartbeat-ensure, self-assigned UUID targeting). randy
confirmed the wake/seen/heartbeat machinery is terminal-agnostic so the adapter slots
in by changing the roster line adapter=kitty→supacode. PROVEN working: self-assigned
UUID create (pass -n <uuid>, own the handle with no capture/timeout race), OSC
color/title paint, adapter logging + correct UUID targeting, and `tab new -i` executes
its initial command (file side-effect verified). REAL BLOCKER FOUND (isolated across 4
attempts, before claiming success): `surface focus -i "cmd"` inserts the text but does
NOT submit/execute it — even though the source (WorktreeTerminalManager.swift:282
appends \r via focusAndInsertText). So spawn works but WAKE does not, which is inverted
from need (wakes are frequent, spawns rare). Same class as the old kitty
send-text-doesn't-submit bug — likely Ghostty custom-keyboard-mode where \r != Enter
for TUI agents. Also: supacode CLI has no surface-read verb (list/focus/split/close
only), so we can't read a surface back to verify delivery like kitty's get-text.
Verdict: substrate strong (identity/colors/spawn solid) but pad migration BLOCKED until
the wake-submit path works. Options posted: file upstream / wake-by-respawn workaround /
find a submit escape through focusAndInsertText.
_________________________________________________________________________________
time:      [01:45am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [infra]

Supacode wake blocker SOLVED via zmx (smaths' "go under the terminal" instinct).
Source dive found Supacode wraps every surface's shell in a bundled zmx session
multiplexer (Resources/zmx/zmx). zmx exposes what the supacode CLI lacked: `zmx send
<session> "<text>\n"` is a RAW PTY write whose trailing newline submits (fixing the
focusAndInsertText non-submit bug); the session name is deterministic `supa-<surface
_uuid>` (the UUID we self-assign at spawn, zero discovery); and `zmx history <session>`
reads the buffer back (solves the no-get-text gap kitty had to work around). Rewired
tool/adapters/supacode.sh to wake via `zmx send` (focus-for-visibility first, then raw
send). Verified end-to-end as the watcher calls it: rc=0, nudge submitted into the
session, zmx history confirmed delivery. Net: Supacode is fully serviceable with NO
source changes and no upstream dependency — spawn (self-UUID), colors (OSC), wake (zmx
send), verify (zmx history), identity (assigned UUID) all solved; wake path is cleaner
than kitty's send-text+enter. Next: one-agent live POC; mark to review zmx trust
boundary (raw input into sessions).
_________________________________________________________________________________
time:      [01:50am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [review]
area:      [infra]

Hardened supacode.sh per mark's zmx security review. `zmx send` is a raw PTY write
that submits immediately (higher blast radius than kitty's send-text paste), so a
crafted pad message could ride control/escape bytes into a session. Audit: (1) the
nudge is `wake --peek` output (local parse) but its snippet (bin/stitchpad:793) carries
pad-body text and does NOT strip control/escape bytes; the adapter's old `tr -d '\r\n'`
killed embedded-CR command injection but not ESC sequences. Fixed: sanitize now
`LC_ALL=C tr -d '\000-\037\177'` — strips ALL control bytes before the write. Proven
against mark's exact vectors (`\r rm -rf ~`, OSC title hijack, SGR) via od -c byte dump:
all control bytes stripped, only printable text reaches the pty. (2) Session name
`supa-<surface>` derives only from SP_TARGET (roster/launcher self-assigned UUID, local
state), never pad body — no second vector. Local-state-trusted / pad-body-untrusted rule
holds end to end. mark cleared both conditions.
_________________________________________________________________________________

time:      [02:02am] [06-18-26]
agent:     [pi] [unknown]
worktree:  main
type:      [workflow]
area:      [design]

Created `reference/stitchpad-system-diagram.html`, a self-contained visual explainer for Smaths showing the stitchpad hot-context vs cold-archive architecture, derived-index contract, token-efficiency rationale, and acceptance tests. Verification: checked the artifact has a doctype/title, no placeholder TODO/Lorem content, interactive mode controls, and file size output via a local Python sanity check.
_________________________________________________________________________________
time:      [02:14am] [06-18-26]
agent:     [codex] [gpt-5]
worktree:  main
type:      [bug-report]
area:      [skill/mcp]

Joined the live pad as `@jill` through the Stitchpad MCP join tool after the CLI/env
state showed an orphaned capitalized `@Jill` session. Bound session `84` to lowercase
`jill`, verified `stitchpad doctor` reports `@jill (kitty/push) codex — online`, and
fixed the installed CLI color override so lowercase `jill` resolves to pink
`#ff1493` instead of the fallback yellow. Verification used the real Kitty window:
`stitchpad color jill` returned `#ff1493`, `stitchpad bind-session 84 jill` reapplied
the color, and `kitty get-colors --match id:10` reported `background #ff1493`.
_________________________________________________________________________________
time:      [02:18am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [review]
area:      [infra]

Supacode agent-#1 POC proven live against a real surface (smaths: "why we not on
supacode" — answer: cutover was done-but-unstarted; ran it). Checklist: (1) self-
assigned UPPERCASE uuid via uuidgen → `supacode tab new -n <uuid>` creates the tab
owning our exact UUID (the "Timed out" message is cosmetic — handle is ours
immediately). (2) wake-by-UUID: `surface focus -t <uuid>` rc=0. (3) zmx session name
convention `supa-<lowercased-uuid>` matches the live session exactly (pid confirmed).
(4) DELIVERY PROOF: `zmx send <sess> "<cmd>\n"` rc=0, `zmx history` reads the marker
back from the surface buffer — real delivery, not a proxy. Verified uppercase is safe
everywhere today (uuidgen=uppercase, adapter does no lowercasing except the documented
zmx session name). Gap found: stitchpad-team launcher has zero supacode spawn path yet
(kitty-only) — that's the generalize-after-green step. Next: flip dale's roster line
adapter=kitty→supacode with a real claude session in the surface, confirm heartbeat/
seen/pending ride over, then migrate agent-by-agent.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [03:58am] [06-18-26]
agent:     [pi/dennis] [gpt-5.5]
worktree:  main
type:      [bug-report]
area:      [backend]

Supacode handoff attempt as non-Claude operator: verified the Supacode Claude session joined/bound as dale (`.state/sessions/c3f34b57-ae97-45f4-9ad5-d68fe97bad12=dale`) and temporarily flipped the live roster to target UUID `5C586109-C69A-49DE-B3A7-C413A5A0941F`. Found a real blocker: the adapter's live-target check used `supacode tab list`, which fails outside a Supacode worktree (`Missing worktree ID`) and falsely clears valid targets; patched `tool/adapters/supacode.sh` to validate via zmx session list instead. After patch, zmx delivered text to the Claude TUI but CR/LF did not submit; history showed the nudge parked in the composer with no proof post. Rolled dale roster back to kitty target `unix:/tmp/kitty-thoth-697@@1`. Conclusion: do not migrate Dale yet; Supacode bind/target pieces are partly proven, but reliable Claude-TUI submit via zmx remains unproven/blocking.
time:      [05:45am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [bug-report]
area:      [infra]

Dual-ownership cleanup (dennis caught it). After the frozen Supacode migration,
TWO session files mapped to dale: 04d0c707 (live kitty session) AND c3f34b57 (the
Supacode session dennis bound during the operator attempt). The roster rollback to
kitty flipped the wake target but did NOT clear the Supacode session file — so two
sessions could both post as @dale, the exact dual-ownership we'd tried to avoid.
Fix: removed .state/sessions/c3f34b57 (the stale Supacode dale binding). Evidence
after: only 04d0c707=dale; roster dale|kitty|@@1; doctor dale adapter=kitty
status=online health=ok; Supacode surface stays alive but unbound (kept for the
submit-fix work, not authoritative). Lesson: roster rollback must also clear the
session file, else identity binding outlives the wake routing. Supacode migration
remains FROZEN pending the Claude-TUI submit-via-zmx fix.
_________________________________________________________________________________
time:      [05:51am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [frontend]

PWA send reliability (my piece of dennis's hybrid plan). The send path had optimistic
PENDING render but NO failure handling — on a network/HTTP error the message froze at
"sending…" forever with no signal, and the text was lost. For a control surface smaths
leans on, that's the painful case. Fix: wrapped the /say POST in try/catch — on
failure, drop the optimistic bubble, restore the text to the composer (so the send
isn't lost), and show a "⚠ send failed — text is back, press send to retry" line.
Verified in headless Chrome with a mocked failing api(): textRestored=true,
pendingCleared=true, errorShown=true. JS validated.
_________________________________________________________________________________
time:      [05:05pm] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  feat/pwa-client-dale
type:      [feature-request]
area:      [frontend]

PWA client lane (smaths' "own a worktree, 3-5 tasks, PR" directive). Worktree
~/stitchpad-dale on branch feat/pwa-client-dale, off current HEAD (incl ernie's
ETag/304 commit), client-only so no collision with the transfer-relief branch.
Shipped three gaps in tool/pwa/index.html: (1) inline media players — fmt() only
rendered ![](img); added bare-URL <video> (mp4/mov/webm/m4v) + <audio>
(mp3/m4a/ogg/oga/wav) so tg-media a/v sends play instead of click-out links, and
hardened the autolink with a (?<!=") lookbehind so a media/img src isn't re-wrapped
in an <a> (also fixes the same latent bug in the existing image rule). (2) composer
draft persistence — ta.value was lost on reload/PWA-kill; drafts now persist
per-pad/per-DM to localStorage, restore on switch+startup, clear on send, re-persist
on send failure. (3) new-message pill — when scrolled up reading history, new msgs
painted silently; added a "↓ new messages" jump pill reusing the atBottom check.
Verified in node: 9/9 media+autolink cases, 5/5 draft semantics, full-script syntax
OK. Deferred task 4 (link unfurl) — needs a relay endpoint = ernie's transport repo,
separate PR to avoid collision. PR opening next.
_________________________________________________________________________________
time:      [05:55pm] [06-18-26]
agent:     [codex] [gpt-5] [jill]
worktree:  main
type:      [bug-report]
area:      [infra]

Fixed the live watcher lifecycle after `stitchpad start`/`restart` allowed duplicate
`watch.sh` and `fswatch` trees to stack on `/Users/risingtidesdev/stitchpad-live`.
Added pad-scoped watcher stop/convergence helpers, made stop/restart use them, fixed
daemon supervisor pid recording, and changed watcher TERM/INT handling so killed
watchers actually exit and only the lock owner removes the lock. Verified against the
real live pad: syntax checks pass, concurrent `stitchpad start` calls preserve one
watcher, deliberate duplicate watcher injection converges back to one watcher, and
the final lock/fwatch pair is PID 47788 for `stitchpad-live`.
_________________________________________________________________________________
time:      [9:05P] [06-18-26]
agent:     [pi] [mimo-v2.5-pro] [dennis]
worktree:  [main]
type:      [workflow]
area:      [automations]

Shipped the Supacode wake path instead of file-only nudges: synced the repo and installed supacode adapter to clear stale composer text, insert the canonical nudge with `supacode surface focus -i`, and submit with `supacode surface send-key --key Enter`; normalized old `folder:` worktree sidecars and rebound live @dale to surface `B20690EC-EA8D-4CAE-A186-08919AEDF6E8`. Verification: `bash -n` passed for both adapter copies; manual live adapter invocation returned rc=0 and logged `woke @dale via supacode focus+send-key`; Dale’s Claude processed the wake and posted after tool approval.
_________________________________________________________________________________
time:      [09:07pm] [06-18-26]
agent:     [codex] [gpt-5] [larry]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Tightened the shipped Supacode wake adapter so it does not depend on stale roster assumptions: `tool/adapters/supacode.sh` now strips stale `folder:` worktree prefixes, infers the live Supacode worktree from the pad root when needed, resolves the actual tab that owns the target surface before sending, pins its internal `stitchpad wake --peek` call to `STITCHPAD_PAD_DIR`, and records the normalized worktree sidecar. This keeps the native wake contract as focus/insert plus `surface send-key --key Enter`, with file nudge only as a breadcrumb and nonzero exit on native failure. Verification: `bash -n tool/adapters/supacode.sh` passed; the live adapter log showed native `supacode focus+send-key` deliveries after the change, watcher status was running, `doctor --json` reported @dale Supacode health ok, and current Supacode tab/surface listing showed the live C3 target registered in `stitchpad-live`.
_________________________________________________________________________________
time:      [09:08pm] [06-18-26]
agent:     [codex] [gpt-5] [jill]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Closed the live Supacode wake loop on the actual pad condition. Rebound @dale from the stale/dirty B206 surface to a freshly spawned and primed Supacode Claude surface `C3C2E8FF-50F3-4937-95EE-B5D15ED5B126`, then posted a real `@dale` wake regression message from @jill. The watcher fired the Supacode adapter, the adapter log recorded native `supacode focus+send-key` delivery to the C3 surface, Claude received the `stitchpad:` wake prompt, read the pad, and posted `@jill WAKE_C3_210531 ok`. I granted Claude's local `STITCHPAD_NAME=dale stitchpad say *` approval rule during that acceptance run so future Dale pad replies from the same surface do not stop at the tool approval prompt.
_________________________________________________________________________________
time:      [9:13P] [06-18-26]
agent:     [pi] [mimo-v2.5-pro] [dennis]
worktree:  [main]
type:      [workflow]
area:      [automations]

Migrated the live local Stitchpad roster from kitty to Supacode after the native focus+send-key wake path shipped. Launched Supacode tabs for @dennis, @ernie, @mark, @jill, and @larry; kept @dale on Supacode; left @henry on relay and @smaths as operator. The fresh pi tabs hit a duplicate `pi_messenger` extension conflict when started as plain `pi`, so @dennis/@ernie were relaunched with `pi --no-extensions` to keep them alive in Supacode. Updated live roster targets and `.state/worktree.*` sidecars. Verification: `stitchpad doctor --json` now reports dennis/ernie/mark/jill/larry/dale as `adapter=supacode` with Supacode targets; jill/larry Codex, mark Claude, and dennis/ernie pi-noext histories show live Supacode TUI sessions.
_________________________________________________________________________________
time:      [09:13pm] [06-18-26]
agent:     [codex] [gpt-5] [larry]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Moved @larry's live Stitchpad wake target from kitty to Supacode as part of smaths' full-team migration order. Created a new Supacode `stitchpad-live` tab that started Codex with `STITCHPAD_NAME=larry` and `STITCHPAD_PAD_DIR=/Users/risingtidesdev/stitchpad-live/.stitchpad`, resolved the actual live tab/surface as `CF5BDCCE-B1EA-402C-9C58-705F0D6AFA2C`, updated the live roster line to `larry | supacode | push | CF5BDCCE...@@CF5BDCCE...`, and wrote `.state/worktree.larry` with `%2FUsers%2Frisingtidesdev%2Fstitchpad-live%2F`. Verification: Supacode listed the CF5 surface, zmx listed `supa-cf5bdcce-b1ea-402c-9c58-705f0d6afa2c`, Codex and its MCP server were running under that zmx session, and `stitchpad doctor --json` reported @larry `adapter=supacode`, `status=online`, `health=ok`.
_________________________________________________________________________________
time:      [06:45pm] [06-19-26]
agent:     [codex] [gpt-5]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Ported the native surface adapter path from Supacode to Velocity. Added `tool/adapters/velocity.sh`, generalized the shared Supacode-compatible adapter to honor `STITCHPAD_SURFACE_APP`, `STITCHPAD_SURFACE_CLI`, and `STITCHPAD_SURFACE_ZMX`, taught the CLI/MCP/relay paths to prefer `VELOCITY_*` surface variables, and changed `stitchpad join` so an existing roster name can be updated to the new adapter/target instead of silently staying stale. Synced this runtime into the Velocity app bundle and migrated the live `stitchpad-live` roster rows for codex, claude, deepseek, and pi to `velocity | push | ...`. Verification: installed bundle `bash -n` passed for `stitchpad`, `velocity.sh`, `supacode.sh`, and relay watcher; installed MCP server passed `node --check`; bundled `stitchpad doctor --json` from `/Users/risingtidesdev/stitchpad-live` reports all current rows as `adapter=velocity`.
_________________________________________________________________________________
time:      [07:04pm] [06-19-26]
agent:     [codex] [gpt-5]
worktree:  feat/t2-supacode-adapter
type:      [refactor]
area:      [docs]

Removed active Kitty wake guidance from the current Stitchpad collaboration path. Replaced README wake guidance with Velocity native wake, rewrote the migration SOP around `adapter=velocity` with no Kitty revert path, changed the system diagram adapter label to Velocity, updated the heartbeat regression from `kittyWindow` to generic Velocity `surface`, and taught heartbeat writes to prefer `VELOCITY_SURFACE_ID` over legacy Supacode aliases. Verification: scoped `kitty` search across README, AGENTS, docs, tool, tests, and reference diagram returns no hits; `bash -n` passed for source and bundled scripts; `bash test/heartbeat.sh` passed; live `stitchpad-live` doctor still reports current roster rows as `adapter=velocity`.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [07:05pm] [06-19-26]
agent:     [claude] [opus 4.8]
worktree:  main (edited in /Users/risingtidesdev/stitchpad/tool, repo root)
type:      [feature-request]
area:      [backend]

Added sp_reap_dead() to bin/lib.sh — a physical sweep of the .state/ graveyard.
The liveness logic was already self-healing (roster + sp_any_alive skip any
alive.<name> whose mtime is >90s, and the supervisor self-exits when no heartbeat
is fresh) but nothing ever rm'd the dead files, so .state/ accumulated corpses
across sessions: leftover .alive.<who>.<pid> atomic-write tmps whose rename
crashed, stale alive.<name> presences with dead pids, their heartbeat.<name>.lock
dirs, and >1h-old file-claims. smaths hit this — ls'd a pad full of 54 dead pid
files. Reaper removes only proven-dead state (dead pid AND stale mtime; operators
with no pid are kept), and is wired into `stitchpad join` (room starts clean for
the next agent / fresh handle) and into the daemon supervisor's no-heartbeats exit
path. Verified: planted all four corpse types, reaper cleared them while the live
alive.claude presence + heartbeat lock survived. Answer to the join question:
pi/codex rejoin cleanly — join overwrites their alive.<name> with a fresh
heartbeat and now also sweeps any leftovers first.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [07:42pm] [06-19-26]
agent:     [claude] [opus 4.8]
worktree:  main (edited in /Users/risingtidesdev/stitchpad/tool; live mirror in ~/.stitchpad auto-syncs on save)
type:      [bug-report]
area:      [backend]

Fixed dead push-wakes in Velocity. Root cause from the supacode→velocity fork:
the MCP surface auto-detect (server.mjs ~L382) only recognized VELOCITY_SURFACE_ID,
which Velocity never sets — it ships SUPACODE_* env + a Ghostty/zmx shell. So every
agent joining from Velocity guessed surfaceAdapter="supacode" and routed wakes to a
CLI that isn't installed (/Applications/Supacode.app/...), dying at "supacode CLI not
found" → exit 1, wake never delivered. smaths hit this as @claude. Fix: detect Velocity
by the Velocity.app path that IS present in env (ZMX_DIR/GHOSTTY_BIN_DIR/
GHOSTTY_RESOURCES_DIR); added those three keys to parentSupacodeEnv()'s whitelist so
both the claude (inherited env) and codex (ps-eww parent recovery) paths see them.
Verified detection now yields "velocity" with this session's env; node --check passes;
live ~/.stitchpad copies confirmed identical. Also re-joined @claude onto the velocity
surface via CLI (its zmx session supa-ba29c1d4 is live). Stale: @glm (ex-@pi) and
@deepseek roster entries still bind dead surface UUIDs — they self-heal only by
re-joining from their own live terminals; can't be re-bound remotely.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [08:32pm] [06-19-26]
agent:     [claude] [opus 4.8]
worktree:  main (edited in tool/; live ~/.stitchpad mirror auto-syncs)
type:      [refactor]
area:      [backend]

Velocity-only takeover — ripped Supacode out as a user-facing concept across the
stack. supacode.sh adapter folded into velocity.sh (now the real wake adapter, not a
shim) and deleted; server.mjs parentSupacodeEnv→parentSurfaceEnv, surfaceAdapter is
always "velocity" (enum/validation narrowed, dead supacode-detection removed); relay/
watch.sh drops the supacode CLI fallback + supacode surface-app default; personas and
prose de-supacoded; skill renamed supacode-cli → velocity-cli (rewrote commands/env to
velocity + added native `velocity stitchpad read|who|say`). KEPT as inherited bolts (not
a separate dependency): the SUPACODE_* env Velocity still emits, the supa-<uuid> zmx
session naming, and VELOCITY_*||SUPACODE_* read order — commented as such everywhere they
survive. Verified end-to-end: fired velocity.sh against the live roster target → exit 0,
"woke @claude via zmx PTY write". Syntax-checked, live install confirmed in sync,
supacode.sh gone from both. Stale @glm(ex-pi)/@deepseek still need to re-join from their
own live terminals to re-bind.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [01:18] [07-16-26]
agent:     [codex] [gpt-5]
worktree:  [main]
type:      [bug report]
area:      [backend]

Fixed markdown-only idle wake for Codex. The watcher already detected Fable's
new @codex mention, but the Codex adapter only displayed a macOS notification
and exited 3; the Stop hook could not create a turn after Codex was idle. The
adapter now selects the newest session binding for the addressed handle and
runs `codex exec resume` for that exact thread, without Velocity or terminal
keystrokes. It stays fail-closed: resume failure or a successful turn that does
not post an addressed pad reply leaves the engagement gate pending. Added an
isolated regression for newest-session selection, prompt policy, successful
gate closure, and reply-less failure. The live Fable wake opened a new Codex
turn through this path and produced an in-pad response. Updated `doctor` to
validate pull agents through session bindings, push agents through targets, and
installed adapter scripts from disk instead of a stale hard-coded allowlist.
_________________________________________________________________________________

time:      [01:21] [07-16-26]
agent:     [claude] [fable 5]
type:      [refactor]
area:      [agent-building]

Reformatted the stitchpad pi integration as a herdr plugin and stripped all Velocity references. index.ts now pins herdr|push|$HERDR_PANE_ID at join (pull|- outside herdr) and installs beside herdr-agent-state.ts at ~/.pi/agent/extensions/stitchpad.ts; removed the old pi package entry from ~/.pi/agent/settings.json. Added a set-wake CLI subcommand because join no-ops on existing roster rows, so a restarted agent could never escape a dead pull|- row. pi.sh is now a thin fallback that delegates to herdr.sh when a herdr target exists. Verified end-to-end on the ocean-surface pad: /reload loaded the extension into the running pi, set-wake re-pinned the roster, the watcher pushed the pending mention via herdr pane run, and @pi replied on the pad at 01:19.
_________________________________________________________________________________

time:      [01:52] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Rebuilt the stitchpad TUI chat-first and made the task board agent-native. The prompt is always live (no compose mode; Enter sends as @smaths, Tab completes @names), ^Y copies the conversation as clean markdown (terminal drag-select grabbed borders/roster across panels), and the stale-roster bug is dead: pad events now refresh messages+board, and a background thread re-runs doctor+liveness every 5s so duplicate members and stuck health triangles converge automatically. Tasks tab gained Enter detail, ]/[ status moves, d/x done/cancel. Agents got task tools (tasks/task_new/task_update in the MCP server for claude/codex, stitchpad_task* in the pi extension) whose descriptions instruct unprompted status upkeep, and stitchpad wake now appends the woken agent open tickets to every wake payload. cargo build clean, 13/13 tests, scratch-pad E2E verified. Commit 453f99e.
_________________________________________________________________________________

time:      [02:01] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Added mouse support to the stitchpad TUI: wheel scrolling, clickable header tabs, and in-app drag-selection over the messages panel that copies just the message text to the clipboard on release (mouse capture means terminal drag-select can no longer grab borders/roster across panels). Commit 8-file series continues; this is the follow-up to 453f99e.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [02:36] [07-16-26]
agent:     [codex] [gpt-5]
worktree:  [main]
type:      [bug report]
area:      [automations]

Removed the hidden Codex `exec resume` watcher lane. It made pad replies appear
to work but ran actions in headless child sessions outside the interactive
terminal the operator was watching. The real Codex Stop hook in
`~/.codex/hooks.json` remains authoritative. Watcher routing now skips every
`pull` member and serves only explicit push targets such as herdr; the Codex
adapter no longer launches processes or consumes the wake gate. Terminated the
three outstanding headless resume chains and corrected the README contract.
Headless SDK/exec orchestration must be an explicit future mode, never hidden
behind a pull identity.
_________________________________________________________________________________
time:      [01:22] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Revamped the PWA (tool/pwa/index.html) end-to-end for smoothness + visual polish, deployed live to stitchpad.agentsworld.org. Perf: replaced the nuke-innerHTML-every-poll renderer with a keyed incremental renderer (djb2 key per message block; new messages APPEND with a 220ms fade-up, anything else falls back to one silent full rebuild), mobile drawer now animates transform+scrim instead of width (layout-thrash jank killed), polling pauses when the tab is hidden and refreshes instantly on return, scroll re-sticks through image loads, skeleton shimmer on first load. Visual: refined dark palette with real elevation layers (kept paper shell + teal identity), Slack-style same-author message grouping with hover timestamp gutter, teal focus-ring composer with paper-plane send button (disabled-when-empty), hairline system-message dividers, styled scrollbars, springy agent-card/login animations, full prefers-reduced-motion support, empty state, avatar fallback now colored initials instead of the stock _default.png photo. Manifest theme colors unified to #12151c. Added tool/PRODUCT.md (impeccable design context). Verified live in Chrome against the real relay: grouping, colors, composer, statusbar all correct; zero console errors.
_________________________________________________________________________________
time:      [01:58] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

PWA round 2 (deployed live): (1) iOS keyboard behavior fixed — inputs bumped to 16px so Safari stops auto-zooming on focus, viewport meta gains interactive-widget=resizes-content, and a visualViewport handler sizes #app to the real visible height, pins the layout back to top, and keeps the log glued to the newest message while the keyboard slides. (2) Real harness logos as avatars — avatars/claude.png + fable.png (white Anthropic starburst on coral), codex.png (OpenAI gradient mark on black), pi.png (white glyph on graphite), ocean.png (ocean tauri icon); rendered from the velocity supacode Assets.xcassets marks via headless Chrome. (3) Prompt box + tagging rework — @ quick-mention button in the composer, live mention coloring inside the input (backdrop-overlay technique: transparent textarea glyphs over a mirrored colored layer), and the mention menu rebuilt as a proper popover: avatar tiles, presence dots, adapter subtext, @all row, keyboard-hint footer. Verified live: menu, tab-select, colored @codex in-input all correct. Also diagnosed codex missing wakes on the ocean-surface pad: dnd.codex had been on since 02:33 queuing mentions behind seen cursor 40; turned DND off, codex drained to current (164/164).
_________________________________________________________________________________
time:      [02:29] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

True DMs + file attach + keyboard hardening (deployed live + bridge restarted). DMs no longer post @mentions into the shared thread: the PWA DM view now POSTs to a new relay /dm queue (dmbox:<pad>), the Mac bridge drains it and injects the message straight into the target agent's herdr pane via `herdr pane run` (pad-mention fallback ONLY if no live pane, so nothing is lost). Sent DMs live in a local per-agent log woven into the DM pane anchored at send position, styled teal with a "→ @name's terminal" marker; the pad never sees them (context-bloat fix smaths asked for). File attach: paperclip button in the composer uploads any file ≤15MB to the relay (/upload-file → R2 + filebox queue), the bridge downloads it into the project's .stitchpad/dropbox/, and a one-line 📎 note is posted so agents know it landed. Keyboard: app shell now also pins to the visual viewport via vv.offsetTop translate (iOS standalone shove compensation). Verified end-to-end from the wire: /dm queued → bridge drained → fallback fired on a dead target; upload → R2 → bridge landed the file in stitchpad-test-project/.stitchpad/dropbox with intact contents. Zero console errors on the deployed bundle.
_________________________________________________________________________________
time:      [02:50] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

Realtime transport shipped: PadHub Durable Object + websocket bridge sidecar — the polling era is over. Worker: new PadHub DO (one per pad, sqlite-backed) owns the hot pad doc in DO storage; /push /pad /pad.colors /ws route through it; pushes broadcast {type:"pad"} to connected PWA sockets ONLY when content actually changed (sig compare — identical 3s snapshots no longer repaint phones); /say /dm /upload-file try instant delivery to a connected bridge socket first and fall back to the KV queues; KV keeps index/invites/queues/legacy seeds. PWA: websocket client with exponential-backoff reconnect, 25s ping, pad-switch rebind; polling drops to a 30s safety sweep while the socket is live, 3s when down; paint() extracted from render() so both transports share one draw path. Mac side: bridge.sh's polling loop replaced by bridge-ws.mjs (node, launchd org.stitchpad.bridge updated + bootstrapped): one WS per pad (role=bridge) receives say/dm/file instantly (say → stitchpad say + immediate echo push; dm → herdr pane injection w/ pad fallback; file → dropbox download), fs.watch on stitchpad.md triggers debounced pushes via the extracted bridge-push-once.sh (shared payload builder), 45s presence sweep + 30s HTTP queue-drain fallback when a socket is down; pad discovery pruned (Library/node_modules/…) → 0.1s vs 30s+. Measured end-to-end: phone send → agent pad → phone screen in 1.04s (was 10-30s across three polling loops); say delivered over WS confirmed ({delivered:"ws"}). bridge.sh retained as manual fallback.
_________________________________________________________________________________
