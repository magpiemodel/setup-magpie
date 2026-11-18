# Plan: move all setup state out of `~/magpie` into `~/setup-magpie`

Goal: `~/magpie` holds ONLY the fresh `git clone` of MAgPIE (plus repo-native
runtime artifacts the clone itself produces: `renv/`, `output/`, `.Rprofile`, …).
Every file the two course scripts write moves to a dedicated work dir
`~/setup-magpie/`. Decisions below are already settled with the user — do not
re-litigate them.

Settled decisions:

1. **Legacy files are moved out of `~/magpie`** (not just tolerated): state
   worth keeping is *moved* to the work dir, junk is deleted.
2. **Full consolidation**: the hidden internal state (`~/.magpie-course/self/`
   relocation copy, `~/.magpie-course-handle`) also moves into `~/setup-magpie/`.
3. **The sandboxed opencode agent stays blind** to the work dir: no extra
   `nono` grant on the launcher. Accept that the agent can no longer read
   `setup-log.txt` (it used to sit inside the allowed cwd).

## Target layout

```
~/magpie/            fresh clone ONLY (+ renv/, output/, … produced by the repo)
~/setup-magpie/      everything the course scripts write
    setup-log.txt          .setup.lock/        .keepalive.pid
    setup-dl-*.pkg         setup-dl-gams.exe
    opencode-dl.tgz        opencode-extract/
    nono-dl.tar.gz         nono-extract/
    .setup-fullrun-ok      .setup-finished
    self/                  (9P relocation copy, setup-magpie.sh only)
    .magpie-course-handle  (code name, setup-magpie.sh only)
```

Both scripts get one constant:

```sh
MAGPIE_SETUP_DIR="$HOME/setup-magpie"
```

It derives from `$HOME`, so the fake-HOME harness scopes every path
automatically — no new harness-overridable constant is needed.

## Facts already verified (trust these, they shape the design)

- **The log needs no profile change**: the `>> logfile 2>&1` fd is opened by
  the *unsandboxed* parent shell and inherited through `nono run` into the
  gate child / full run. `magpie_log` writes to stdout, so it lands in the
  log regardless of where the file lives. No sandboxed process ever touches
  the work dir **by name** (check the `--check-only` child yourself: it opens
  no log and must NOT sweep or mkdir).
- `.setup-fullrun-ok` / `.setup-finished` / lock / pidfile are all written by
  the unsandboxed parent. Moving them is safe.
- The nono profile **content does change** via `read_file` only: it embeds the
  relocated `MAGPIE_SELF` path and the handle-file path (setup-magpie.sh
  ~line 1682). Per the hard rule this **requires bumping
  `MAGPIE_PROFILE_SCHEMA` 9 → 10**. Existing marker + `cmp` replacement logic
  swaps stale profiles. Read/write dir lists are otherwise unchanged.
- `magpie-opencode.sh` never uses the handle file, 9P relocation, or
  `--script-hash` — consolidation touches only `setup-magpie.sh`.
- `--script-hash` early-exits in `magpie_entry` (~line 2352) with **no side
  effects** — work-dir mkdir and sweep must run strictly after that exit.

## Changes — `setup-magpie.sh`

- Add `MAGPIE_SETUP_DIR="$HOME/setup-magpie"` near the other constants
  (~line 125–136). Retarget every setup artifact:
  - log: bootstrap redirect (~2357–2358), `magpie_fail` `$logfile` (~345)
    incl. the "everything else: …" line, crash trap tail (~546), gate-child
    `>>` fd (~2070), verdict comment (~2280).
  - `.keepalive.pid` (~430, ~518), `.setup.lock` (~548, ~559),
    `setup-dl-$1.pkg` (~760), `opencode-dl.tgz` + `opencode-extract`
    (~848–849), `nono-dl.tar.gz` + `nono-extract` (~902–903),
    `setup-dl-gams.exe` (~1341), `.setup-fullrun-ok` (~2091–2092, ~2153).
    The run path stored *inside* `.setup-fullrun-ok` stays relative to
    `~/magpie` (e.g. `output/default_…`) — `magpie_full_run_complete` calls
    keep `"${MAGPIE_REPO:-$HOME/magpie"}/$fullrel"` semantics; do NOT change
    the clone path `~/magpie` anywhere (clone body, renv, gate `cd`, `output/`
    checks, `df` target below notwithstanding).
  - `df -Pk` disk probe (~587): point at `"$MAGPIE_SETUP_DIR"` (exists by
    then; same filesystem as `$HOME`).
  - `magpie_entry` normal path (~2352): `mkdir -p "$MAGPIE_SETUP_DIR"`,
    failure verdict text → "cannot create ~/setup-magpie - check disk space
    and folder rights". `--check-only` branch: drop the `mkdir -p ~/magpie`
    (child needs neither dir) — verify nothing else in the child needs it.
  - Legacy `rm -f setup-help.txt setup-help-profile.json` (~2197) folds into
    the sweep; remove the standalone line.
- 9P relocation (~490): dest → `"$MAGPIE_SETUP_DIR/self/setup-magpie.sh"`;
  keep 700/600 modes, mkdir parent comes from the work-dir bootstrap.
- `MAGPIE_HANDLE_FILE` (~125): `"$MAGPIE_SETUP_DIR/.magpie-course-handle"`.
- `MAGPIE_PROFILE_SCHEMA` → `"10"` (~130).
- Clone guard (~1839–1854): keep the legacy allowlist verbatim as
  belt-and-braces (a file the sweep could not remove must still not block the
  clone); unknown-entry verdict unchanged.
- New sweep function (see "Sweep" below), called from `magpie_entry` on the
  normal path only — after the `--script-hash` exit, after work-dir mkdir,
  before `magpie_main`; never in the `--check-only` child.

## Changes — `magpie-opencode.sh`

- Same constant; retarget: log (~98, ~869), `.keepalive.pid` (~159, ~203),
  `.setup.lock` (~223, ~231), `df -Pk` (~257), opencode/nono dl + extract
  (~456–457, ~509–510), `.setup-finished` write (~735) and fast-path check
  (~788), bootstrap `mkdir -p` + failure text (~866–867).
- Clone guard whitelist (~686–701): keep as-is (defensive, same list).
- Sweep (same function) at entry, before `magpie_fast_path_ok` — **the fast
  path must run after the sweep** so a migrated `~/magpie/.setup-finished`
  already sits in the work dir when the fast path checks it.
- Launch (~755): unchanged (`--profile nolabs-ai/opencode --allow-cwd`).

## Sweep (identical semantics in both scripts)

Runs unsandboxed, once, on every normal run. Best-effort (`2>/dev/null`,
`|| true`) — it must never fail the setup. Targets:

- `~/magpie` — MOVE into `"$MAGPIE_SETUP_DIR"` (only when the target is
  absent; if the target exists, append for the log / delete the copy for the
  markers):
  - `setup-log.txt` (preserve history), `.setup-fullrun-ok`,
    `.setup-finished`.
- `~/magpie` — DELETE (junk with no value at a new path): `setup-dl-*`,
  `opencode-dl.tgz`, `opencode-extract`, `nono-dl.tar.gz`, `nono-extract`,
  `.setup.lock/`, `.keepalive.pid`, `setup-help.txt`,
  `setup-help-profile.json`.
- `setup-magpie.sh` only:
  - MOVE `~/.magpie-course-handle` → work dir if the new handle is absent —
    **existing code names must survive**;
  - `rm -rf ~/.magpie-course` (relocation copy regenerates on demand).
- Never touch anything else in `~/magpie`; match the exact names above plus
  the `setup-dl-*` glob only. A stray unknown file must still trip the clone
  guard exactly as today.

## Sandbox / profile recap

- `magpie-profile.json`: content changes only in `read_file` (new `self/` and
  handle paths) → schema bump 10. Validate via the existing
  `nono profile validate` step and the AGENTS.md sim trick:
  `HOME=<fake> MAGPIE_SOURCED=1 bash -c '. ./setup-magpie.sh; MAGPIE_OS=linux …; magpie_build_nono_profile'`
  + stub `nono` checking the JSON paths exist.
- Launcher profile (`nolabs-ai/opencode` pack) and launch flags: unchanged.

## Text / docs / tests

- `spec-setup-magpie.md`: rewrite "All state lives under `~/magpie`…"
  (~45–58), layout/log (~28, 183, 459, 580–581, 734), lock/keepalive (~142 ff
  where applicable), full-run marker (~518–558), guard + rationale (~477),
  relocation + handle + `read_file` (~1676–1692 behavior), gate notes
  (~419, 612). Add the sweep + migration + schema-10 rationale.
- `spec-magpie-opencode.md`: same story (~26, 65, 108, 116, 132, 142–143,
  193–194, 231, 262, 381–385) incl. fast-path marker migration and guard
  whitelist note.
- `AGENTS.md`: "the log" → `~/setup-magpie/setup-log.txt` (top paragraph),
  one line on the legacy sweep; keep everything else.
- `README.md`: unchanged (never mentions the log; "nono blocks access outside
  the magpie folder" stays true — agent is blind to the work dir).
- `.gitignore`: add `setup-log.txt`, `setup-dl-*`, `opencode-dl.tgz`,
  `opencode-extract/`, `nono-dl.tar.gz`, `nono-extract/`, `.setup.lock/`,
  `.keepalive.pid`, `self/` (a teacher running the script from a
  `~/setup-magpie` checkout now dirties it).
- `tests/test-setup-magpie.sh` + `tests/test-magpie-opencode.sh`: retarget
  every setup-artifact expectation from `$HOME/magpie/…` to
  `$HOME/setup-magpie/…` (~350 `$HOME/magpie` hits total — keep the ones that
  are genuinely clone paths: clone, renv, `output/`, gate cwd, marker content
  relative paths). Update profile-JSON assertions (new `read_file` paths,
  schema `10`). New scenarios (follow the `new_env` + `FN_BODY`/`run_fn`
  idiom, `sec` headers):
  - old-layout `~/magpie` (log + fullrun marker + finished marker + junk) →
    after run: work dir holds the moved state, `~/magpie` holds none of our
    names, clone proceeds;
  - handle migration preserves an existing code name; no handle → fresh one
    in the new place;
  - fast path hits via a migrated `.setup-finished`;
  - work-dir mkdir failure → the failure verdict, no crash;
  - stray unknown file still blocks the clone (both scripts);
  - `--script-hash` still side-effect-free (work dir NOT created);
  - relocation dest is `~/setup-magpie/self/…` (9P sim path).

## Hard rules to honor (from AGENTS.md)

- bash 3.2 (`/bin/bash` on macOS): no `[[`, no associative arrays/mapfile;
  both scripts stay `shellcheck -s bash` clean.
- Specs are the design contract — update both spec files in the SAME change.
- `MAGPIE_PROFILE_SCHEMA` bump is mandatory here (profile content changes).
- Keep the `__PASTE_CONTENTS_OF_gamslice.txt_HERE__` placeholder intact.
- Do NOT hash the raw file for the feed; `--script-hash` stays
  side-effect-free (new AGENTS.md rule).
- Commit style: short, lowercase, one-line (e.g. `move setup state to
  ~/setup-magpie`) — one commit is fine.

## Verification

```
bash tests/test-setup-magpie.sh
bash tests/test-magpie-opencode.sh
bash -n setup-magpie.sh && bash -n magpie-opencode.sh
shellcheck -s bash setup-magpie.sh magpie-opencode.sh   # if available
```

Plus the sim-trick profile check above. `(shellcheck not found - skipped)` is
expected when neither binary exists — never a problem.
