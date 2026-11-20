# AGENTS.md

Two standalone student-facing course scripts for MAgPIE (WSL2-Ubuntu + macOS),
each with a paired spec and an offline bash test harness:

| script | what it is | spec | tests |
|---|---|---|---|
| `setup-magpie.sh` | full course install: apt/tools, TinyTeX, GAMS + licence, nono profile, sandbox gate, sandboxed `start.R` default run | `spec-setup-magpie.md` | `tests/test-setup-magpie.sh` |
| `magpie-opencode.sh` | one-command installer + sandboxed opencode launcher | `spec-magpie-opencode.md` | `tests/test-magpie-opencode.sh` |

`README.md` is the students' moodle post, not dev docs.

Both course scripts keep ALL their state (log, lock, pidfile, downloads,
markers, handle) in the work dir `~/setup-magpie`; the running log is
`~/setup-magpie/setup-log.txt`
(everything that is not a student-facing `magpie_say` line: step
attempts, diagnostics, sandbox-gate child output). When the user says
"the log", they mean that file. `~/magpie` is the clone alone; at entry
both scripts run `magpie_sweep_legacy`, which moves old-layout state
out of `~/magpie` (and `~/.magpie-course-handle`) into the work dir and
deletes the leftover junk names, best-effort.

## Commands

```
bash tests/test-setup-magpie.sh
bash tests/test-magpie-opencode.sh
bash -n setup-magpie.sh             # syntax check of either script
```

Both suites are fully offline: fake HOME, stub binaries behind a minbin
whitelist, curl stub records feed uploads locally, scratch under `.tmp/`.
If `shellcheck` is on PATH (or `tests/shellcheck`), the suite asserts it —
both scripts are expected to be `shellcheck -s bash` clean.
`(shellcheck not found - skipped)` at the end of a run is the expected
informational notice when neither exists — never report it as a problem.
On Linux, silence it by unpacking the static GitHub-release binary to
`tests/shellcheck` (already gitignored; v0.11 is the pinned baseline).

## Hard rules

- **bash 3.2** (macOS stock `/bin/bash`) for both scripts: run via `bash file`
  only, no `[[`, no associative arrays/mapfile.
- **The specs are the design contract.** Update the matching spec file in the
  same change as any behavior change; the specs carry the rationale the
  harness asserts.
- **Any change to the generated `magpie-profile.json` content requires bumping
  `MAGPIE_PROFILE_SCHEMA`** — stale profiles are detected/replaced via the
  marker in `meta.description`.
- **GAMS licence:** the repo copy must keep the
  `__PASTE_CONTENTS_OF_gamslice.txt_HERE__` placeholder. Teachers paste the
  real slice into their distributed copy; never commit a filled script
  (public repo, licence would leak).
- **Feed version hash masks the teacher fill-ins** (`STATUS_URL=` line and
  the `COURSE_GAMSLICE` heredoc body, in `magpie_setup_version`): one build
  = one hash across filled copies; the canonical value comes from
  `bash setup-magpie.sh --script-hash` (early exit, no side effects). Never
  hash the raw file for the feed again.
- **Harness restrictions are floors; a user's "do not" is a ceiling. Neither
  lifts the other; they only tighten.**
  - Floor: in plan mode, no edits, no state-changing commands, no delegating
    them to a subagent — **even if the user asks to implement now**. Answer
    with the agent switch, not the work.
  - Ceiling: a mode/agent switch or a "Plan mode ended" note makes writes
    *possible*, never *authorized*. "Do not implement" stands until a LATER
    USER MESSAGE releases it.
  - No keystroke rituals ("switch agents and I'll implement") — they turn any
    later switch into false consent. Nothing released it → stop and ask.
- Commit style: short, lowercase, one-line what-fixed (see `git log`).

## Harness idioms (setup-magpie suite)

- Scenario = `new_env`, then `FN_BODY='<shell run after the script is
  sourced>'` + `run_fn [VAR=value ...]`; assertions: `grep_ok/grep_no/
  ret_is/cnt_is/file_ok/nofile_ok/mode_is`, `sec` for section headers.
- `run_fn` exports `VAR=value` args **before** sourcing (source-time
  defaults honor them); assignments inside `FN_BODY` override afterwards.
  Harness-overridable constants: `MAGPIE_MAGPIE_URL`,
  `MAGPIE_GFORTRAN_DIR(_NEW)`, `MAGPIE_TOOLCHAIN_DIRS(_DARWIN)`,
  `MAGPIE_DPKG_DIRS`, `MAGPIE_OS_RELEASE`.
- git is made hermetic (`GIT_CONFIG_GLOBAL=/dev/null`) — never rely on host
  git config in scenarios.

## Sandbox gotchas (verified on real course machines)

The real targets run everything inside `nono` sandboxes (Landlock); typical
agent sandboxes cannot execute `nono` — verify profile changes with the sim
trick instead: `HOME=<fake> MAGPIE_SOURCED=1 bash -c '. ./setup-magpie.sh;
MAGPIE_OS=linux ...; magpie_build_nono_profile'` plus a stub `nono` on PATH
that checks the JSON paths exist.

- Landlock grants do **not** follow symlinks out of a granted tree:
  `/usr/lib/R/etc/*` are symlinks to `/etc/R` (profile resolves the target
  with R's `normalizePath` and lists it), and `/mnt/c` (9P) cannot be
  enforced at all — the script relocates itself to `~/setup-magpie/self/`.
- Compiles need `~`-external trees the pack profile lacks: `/usr/libexec/gcc`
  (cc1), `/usr/lib/gcc` (collect2), `/usr/include`, and `/var/lib/dpkg`
  (dpkg-query requirements check).
- Packages write `tools::R_user_dir()` folders at load time (`gdtools` inside
  `ggiraph`): R user dirs are registered caches AND profile write entries.
- On WSL2 nono prints "No path denials were observed" even when Landlock
  denied reads — trust the failing command's output, not that line.
- Piped stdin into `start.R`: its top block can ask exactly two
  questions, both reading `gms::getLine`, both treating an empty line
  as YES and crashing at EOF (`character(0)` through the `&&`):
  "Update now?" (near-certain first run - hydrate installs
  graph-resolved versions, not feed-latest) and fixDeps "Try to fix
  automatically?". Both want `y`, so pipe `y\ny` unconditionally -
  prompt-count-independent. A yes-to-updates may stop the session via
  `piamenv::stopIfLoaded` (gms is loaded by the ask itself) AFTER the
  renv writes land; the step retries once on that signature. Never
  branch on `~/magpie/renv.lock`: a root lock never exists (start.R
  snapshots into `renv/archive/` only; magpie gitignores the root
  lock), and `</dev/null` crashes `gms::getLine`.
