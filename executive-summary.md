# executive-summary.md — setup-magpie.sh fix round

Change set: `72b6cc4..a8b20e7` (27 commits). Verified by per-fix commits,
ten fresh-eyes verification units, and a three-round review-fix loop.

## Assertion counts

| suite | before | after |
|---|---|---|
| tests/test-setup-magpie.sh | 503 | 616 (617 with the shellcheck assertion) |
| tests/test-magpie-opencode.sh | 180 | 187 (188 with the shellcheck assertion) |

Both suites run offline: fake HOME, stub binaries, minbin whitelist.
The launcher suite is the `magpie-opencode.sh` harness (regression scope:
its own setup flow, untouched except the two scoped fixes below).

## The nine verified fixes (before -> after)

1. TinyTeX on macOS: only `~/.TinyTeX` was searched -> `magpie_texbin`
   and the heal loop cover `~/Library/TinyTeX` AND `~/.TinyTeX` on every
   OS; the darwin nono profile reads both.
2. Sudo cooling: a warm sudo timestamp could survive into sandboxed runs
   -> `magpie_stop_keepalive` runs `sudo -k`; setup stops the keep-alive
   right after the licence step (last sudo user); in
   `magpie-opencode.sh` the `sudo -k` sits behind the pidfile, so the
   fast path never touches sudo. Harness stubs now probe the sudo state
   AT the gate/launch/full-run instants.
3. Stale generated profile: an old `magpie-profile.json` was kept
   forever -> `meta.description` carries a schema marker
   (`MAGPIE_PROFILE_SCHEMA`); our stale file is regenerated, old copy
   kept as `.bak`; a foreign file is still kept untouched.
4. Licence checks: any "licensee" banner passed -> with the licence
   embedded, the banner must name `MAGPIE_COURSE_LICENSEE`
   (Potsdam-Institut); demo|expired FAILs always; the weak generic check
   only runs otherwise. Warning fires once per run (cached).
5. GAMS outside ~/gams: licence/profile/PATH assumed `~/gams` ->
   `magpie_gams_sysdir` (pinned folder, else PATH install, else macOS
   framework) feeds all three; the linux profile gets an extra read
   entry; an existing non-writable licence dir warns instead of dying.
6. Ubuntu floor: an Ubuntu < 24.04 box wasted the whole apt step then
   failed at the checks -> fail-fast with the WSL hint, before anything
   installs.
7. Dev-lib skip guard: R + pandoc let an old image skip apt although the
   -dev packages were missing -> nine representative packages must
   report `install ok installed` (a half-configured package does not
   count) or apt runs again.
8. Sandbox gate output: the check block went into the log only ->
   `tee -a setup-log.txt >&4` puts it on screen AND in the log exactly
   once; the child's exit code decides via `PIPESTATUS[0]`.
9. Clone URL: any URL-string difference from the configured origin read
   as "not a magpie clone" -> normalized keys (scheme, user@, scp colon,
   `.git`, trailing slash); official org/repo and same-basename forks
   are accepted with a log note; empty origin proceeds.

## Smaller issues fixed

- PII sanitizer: regex `gsub` replaced by literal token-boundary matching
  (`litrep`); hostname minus `.local` and the account's real name
  (`magpie_realname`) are stripped too; short names no longer hit inside
  words.
- gams licence probe: ran GAMS in an uncleaned `mktemp -d`, and (review
  round) could fall back to the CURRENT folder when mktemp failed - GAMS
  writes there. Now: scratch dir only, removed afterwards; no scratch
  dir = explicit FAIL line.
- rc files: PATH dedupe uses adjacency (comments, longer paths, and
  commented-out exports no longer suppress a needed line); `HU_API_KEY`
  / `MADRAT_MAINFOLDER` / `RENV_PATHS_CACHE` greps anchored; a missing
  final newline is closed before every append (`magpie_rc_newline`, both
  scripts) so two exports can never merge into one broken line.
- Keep-alive: 720 ticks (12 h) and it watches the owner pid captured
  BEFORE the fork - `$PPID` inside the subshell is the OUTER parent, so
  the old loop kept refreshing after a killed owner (proved by a SIGKILL
  test).

## Review-loop findings (beyond the plan)

- Round 1: no-scratch probe FAIL branch; `magpie_rc_newline` (setup).
- Round 2: same newline guard in `magpie-opencode.sh` (granted scope).
- Round 3: `mktemp || return 1` on the launcher config write; nothing
  substantial - loop converged.
- Verification units added 28 setup and 5 launcher discriminating
  assertions, including the
  dpkg `install ok installed` requirement, the trailing-slash URL rule,
  the empty-origin note guard, and the name-over-demo precedence pin.

## Residuals (agreed, not defects)

- A real GAMS demo banner is unverifiable offline; the demo|expired
  rejection stays defense-in-depth next to the licensee name check.
- Ubuntu 22.04's r-base 4.1.2 age is distro knowledge; the floor is the
  guard, and `magpie_have_r` re-checks after any install anyway.
- The sanitizer skips replacement tokens shorter than 2 characters
  (1-char usernames do not exist on Linux/macOS accounts).
- `magpie-opencode.sh` keeps its plain substring rc dedupe and 90-tick
  keep-alive (launcher scope; its binaries have explicit fallbacks).
- `magpie_url_key` normalizes `ssh://host:port/...` oddly (port lands in
  the path) - fails closed: odd key + same basename still accepted, an
  unrelated repo still rejected.
- Same-basename fork acceptance can accept any host's `magpie` repo -
  teacher decision; every acceptance logs "origin is ... using the
  existing clone".
- macOS-only paths (dscacheutil real name, pkg framework GAMS, TinyTeX
  root) are covered by stubs, not by a real macOS run.
