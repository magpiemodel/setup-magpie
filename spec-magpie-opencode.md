# magpie-opencode.sh - spec (essential setup + daily launcher)

Status: implemented in magpie-opencode.sh (tests: tests/test-magpie-opencode.sh).
Date: 2026-11-10.

## 1. Purpose

`magpie-opencode.sh` is the students' single entry point, day one and every
day after:

1. First run: installs the essential tool chain (opencode + nono + HU
   config + nono profile + magpie clone), then opens opencode inside the
   nono sandbox in `~/magpie`.
2. Later runs: starts `opencode` in the sandbox directly (fast path), in
   well under a second, without touching sudo or the network.

Essential subset of `setup-magpie.sh` (the full course setup). Out of
scope here (the course script keeps these): GAMS, licence, R, TinyTeX,
pandoc, renv, sandbox self-check gate.

Works on macOS (Apple Silicon and Intel) and WSL Ubuntu. No Homebrew -
Homebrew 5 refuses Intel Macs, which broke one student.

Support model: the student reads the failure verdict aloud (or
screenshots it) to the TA - step, system, last log line and the path of
`~/setup-magpie/setup-log.txt`, which holds the rest. No course status
feed, no code name - nothing is uploaded anywhere.

## 2. Design decisions

- One file, both OSes. Branch on `uname` (Darwin | Linux).
- Entry-point duality: launcher first, installer second. A marker file
  (`.setup-finished`) makes daily starts cheap; the fast path still
  re-verifies every essential with local checks, so a broken install
  self-heals on the next start.
- No `curl | bash` anywhere. Every download is a pinned, sha256-checked
  release archive. The extracted binary is placed and chmod'ed by this
  script only.
- Sudo is asked ONLY when a sudo-requiring step actually runs (apt or
  CLT install) - never upfront, so machines that already have
  git+curl/CLT see no password prompt at all. Asked blind, in a retry
  loop. The keep-alive loop prevents timeout re-prompts during that step
  but is stopped before any opencode launch, together with the cached
  sudo timestamp (`sudo -k`): no warm sudo credential may
  exist while the sandboxed agent runs.
- Mistyped password = ask again, in a loop; never an error block.
- Errors are only reported when reproducible: every failing step first
  gets in-run retries, then a second full pass in a fresh process. Only a
  failure that repeats in pass 2 prints the failure verdict. Exit on the
  first reproducible error.
- opencode opens as a CHILD process, not an exec: the script survives the
  session, can tell "student closed opencode" from "sandbox never came
  up", and self-repairs the latter (6.11).
- A sandbox smoke test must pass before the finish marker is written - a
  broken sandbox can never produce a marker that fails silently every
  day (6.10).
- Users do not read terminal output. The full run goes to a log file.
  Only these ever reach the screen: `[HH:MM:SS]` heads-up lines before
  slow steps, `OK:` lines (tool installed + in PATH), the password-retry
  and auto-retry lines, and the failure verdict.
- Resilience extras: disk guard (< 4 GB free = abort with cleanup hint),
  setup-path lock so two windows cannot install at once, `INT`/`TERM`
  traps so Ctrl+C always reaps the keep-alive loop of the owner -
  non-owner exits never touch it.
- Everything the script writes lives in the work dir `~/setup-magpie`
  (`MAGPIE_SETUP_DIR`, derived from `$HOME`), created first at entry:
  log, lock, keep-alive pidfile, downloads and the finish marker.
  `~/magpie` is the clone's folder alone - only the clone step creates
  it, and the clone stays `git init` + fetch + checkout instead of
  `git clone` (an existing target may legitimately hold clone or
  legacy leftovers). The SAME file names sit in `setup-magpie.sh`'s
  work dir, so both course scripts share one layout and one sweep:
  `magpie_sweep_legacy` runs at entry right after the work-dir mkdir -
  BEFORE the fast-path check, so an old-layout machine whose state
  still sits in `~/magpie` has its `.setup-finished`/
  `.setup-fullrun-ok` markers and its `setup-log.txt` moved in (append
  on log conflict, work-dir copy wins on marker conflict) and the
  dead-layout junk deleted (`setup-dl-*`, dl tarballs, extract dirs,
  help dumps, old lock + pidfile under `~/magpie`) - every removal
  best-effort, the function always returns 0, and a migrated install
  lands straight on the fast path.
- Foolproof against how it is run: shebang `#!/usr/bin/env bash` from
  line 1, run via `bash file` only. Baseline: bash 3.2 (macOS stock
  /bin/bash), enforced by the harness bash32 guard.
  No bash-only syntax anywhere (no `[[ ]]`, no arrays, no process
  substitution). All paths absolute via `$HOME`; the starting directory
  never matters.
- No course-support extras: the course status feed and the animal code
  name are gone. Nothing is uploaded; the failure verdict is the only
  support channel.
- HU LLM service is preselected by `"model": "hu/llm3"` in the opencode
  config. It cannot be tested off HU network - not part of any check.

## 3. Files

- `magpie-opencode.sh` - student deliverable (standalone)
- `spec-magpie-opencode.md` - this file
- `setup-magpie.sh`, `README.md` - untouched

## 4. Pinned block (top of file, machine-filled - not hand-edited per course)

- `OPENCODE_VERSION` + sha256 of the four npm target archives (see 6.3).
- `NONO_VERSION` + sha256 of the four release tarballs (see 6.4).
- `NONO_PACK_VERSION` - the pinned `nolabs-ai/opencode` pack version
  (see 6.8): the pack defines the sandbox, so it is pinned like the
  binaries. No checksum needed: nono verifies the pack signature itself.
- Filled by the implementer when the script is written and tested, not
  by the teacher: for each asset URL,
  `curl -fsSL <url> | sha256sum` (macOS: `shasum -a 256`).
- Placeholder guard: the template ships with placeholder values. Normal
  mode aborts instantly while any placeholder is present - "script
  incomplete: pinned versions/checksums missing" - so an unfilled file
  can never reach students.
- No auto-updater (dropped as YAGNI): pinned npm/GitHub assets stay
  downloadable indefinitely, so the file does not rot. Re-pinning is
  only needed to ship newer tool versions - bump the version, recompute
  per the one-liner above.

## 5. Script skeleton

The body runs as one function call, `main >> ~/setup-magpie/setup-log.txt 2>&1`
- a function-scoped redirect, never a global `exec`: when the file is
pasted into a terminal, the student's shell keeps its own stdout after
the last line. The real terminal is saved on fd 4 (`exec 4>&1`) at
entry; `say()` writes to fd 4.

Order of operations:

1. `mkdir -p ~/setup-magpie` (the work dir), then `magpie_sweep_legacy`
   (2) - the entry never creates `~/magpie`, only the clone step does.
   On mkdir failure: the failure verdict on fd 4 only (the
   file save is impossible here) - nothing else can work.
2. Detect OS (`uname`): `Darwin` -> mac branch, `Linux` -> ubuntu branch.
   Anything else: failure verdict, exit.
3. `export HU_API_KEY="${HU_API_KEY:-required-but-not-used}"` - needed by
   BOTH paths (opencode requires the variable to exist; the value is
   unused, nono does not route HU - the endpoint needs no real credential).
4. If neither `MAGPIE_FORCE_SETUP=1` nor `MAGPIE_REPAIR=1` is set and
   the fast path passes (6.1): launch opencode (6.11). The fast path
   skips all of the following: no lock, no disk check, no sudo.
   `MAGPIE_REPAIR=1` must skip the fast path - the marker is still
   present after a quick-fail, so honoring it here would relaunch the
   broken sandbox and never run the repair (6.11).
5. Setup path starts: root guard (never run as root - dotfiles and
   configs must stay user-owned), then the placeholder-pin guard (4).
   Then disk check: free
   GB via `df -Pk ~/setup-magpie`, below 4 the failure verdict aborts with the
   per-OS hint ("free space in WINDOWS (C: drive)" / "empty the Trash
   and delete big files"). Then take the lock (below) - only after it is
   held: steps. sudo is asked inside the apt/CLT step bodies only, when
   they actually run (6.2).
6. End of setup path (all steps green): sandbox smoke test (6.10), write
   the marker, then launch opencode (6.11).

Concurrency lock (setup path only):

- `mkdir ~/setup-magpie/.setup.lock` is atomic everywhere (macOS has no
  flock). On success the pid goes into `~/setup-magpie/.setup.lock/pid`, the
  EXIT trap of the OWNER (trap pid == pidfile pid) removes the dir and
  stops the keep-alive.
- Lock exists: read the pid.
  - pid is our own `$$`: we already own it - an `exec` keeps the pid,
    and an in-process repair re-enters with the same pid. Keep the
    lock, re-arm the EXIT trap (exec clears trap handlers - the
    re-armed trap again removes the lock and kills the keep-alive),
    continue.
  - alive (`kill -0`): one line "setup is already running in another
    window" (fd 4), exit 0. This non-owner exit has NO side effects:
    the EXIT trap is gated on ownership, so it leaves the owner's
    lock and keep-alive untouched.
  - dead (crash residue): remove and take the lock.
- The lock is held for the whole life of the setup-path process, also
  during the opencode session and across pass-2/repair execs (same
  pid). No other window can install while a setup is live.
- `trap 'exit 130' INT TERM`: Ctrl+C then still runs the EXIT trap, so
  the owner's sudo keep-alive loop never outlives its script. Non-owner
  exits never stop it - only the owner does, or the launch step (6.11).

On a clean run the script only exits 0 after opencode was used and
closed. A broken install never gets the marker (the smoke test gates it),
and the fast path re-checks the essentials anyway (6.1).

## 6. Steps

Every step is skip-if-done. Every check is local (stat / `command -v`) -
no network in a skip decision. Check blocks of the full scripts are not
part of this script.

Before every slow step that actually RUNS (never on a skip), print one
heads-up to the screen: `say_progress` writes
`[HH:MM:SS] - installing <tool>, about X min...` to fd 4.

| step | heads-up text |
|---|---|
| apt update + git/curl install | `about 1-2 min` |
| Xcode CLT install | `about 5-20 min, please wait` |
| opencode install | `about 1 min` |
| nono install | `about 1 min` |
| nono profile pull | `about 1 min` |
| magpie clone | `about 2-5 min` |

### 6.1 Fast path (daily launcher)

Taken when ALL of these pass, and neither `MAGPIE_FORCE_SETUP` nor
`MAGPIE_REPAIR` is set (a repair must reach the steps, esp. the forced
re-pull in 6.8):

- `~/setup-magpie/.setup-finished` exists (a marker migrated from the
  old `~/magpie` position counts - the entry sweep moved it before
  this check ran)
- `~/magpie` is a clone with a resolvable HEAD (`git rev-parse HEAD`,
  with a local `.git` test first so git never walks up into a parent
  repository)
- `opencode` resolves: `command -v`, else `~/.opencode/bin/opencode`
  executable
- `nono` resolves: `command -v`, else `~/.nono/bin/nono` executable
- `~/.config/nono/packages/nolabs-ai/opencode/package.json` exists AND
  its `version` equals the pinned `NONO_PACK_VERSION` (the pulled
  profile is in place, at the right version)
- `~/.config/opencode/opencode.json` exists

On success: one timestamped launch line appended to the log, then launch
opencode as a child (6.11). No sudo, no network, no `nono profile list`
call - the checks are only stat/PATH lookups, so the
start is near-instant.

The marker is a shortcut, not a gate: if it exists but a check fails, the
script falls through to the setup path and repairs the gap
(skip-if-done steps make that cheap). The marker is never deleted; the
setup path rewrites it when complete.

Marker content (never parsed, debug aid): creation timestamp,
`nono --version`, `opencode --version`.

`MAGPIE_FORCE_SETUP=1 bash magpie-opencode.sh` always runs the setup
path (escape hatch for the TA).

### 6.2 sudo (setup path only)

- First touch: `sudo -n true` - if the timestamp is already valid, print
  nothing. Otherwise print one line: password asked once, typed blind,
  nothing shows.
- `sudo -v` in a loop: sudo itself offers three blind tries. If it gives
  up, print "Password not accepted - try again" (fd 4), `sleep 2`, run
  `sudo -v` again. Cap 6 rounds; then the failure verdict.
- Keep-alive: started only when a sudo ask happened. Background loop
  `sudo -n true` every 60 s, self-exit after 90 iterations. Writes its
  pid to `~/setup-magpie/.keepalive.pid`; before spawning, a live pid is
  detected with `kill -0` (a second pass must not stack loops). Stopped
  when the lock OWNER exits (the EXIT trap is gated on lock ownership,
  5) and ALWAYS at the start of the launch step (6.11) - the launch
  stops it even on the fast path, where no lock is held. Non-owner
  exits never touch it: a second window must not kill the running
  owner's loop. Stopping also runs `sudo -k` - but only when the
  pidfile existed: it proves a prompt happened, and killing the
  refresher alone is not enough (sudo remembers the password for
  minutes). Without a pidfile the stop is a no-op, so the fast path
  never touches sudo. The sandboxed opencode must never find a warm
  sudo credential.
- When is sudo asked: only inside a sudo-requiring step that actually
  runs (apt or CLT) - both bodies warm up through this same loop first.
  Machines that skip those steps (git+curl present, CLT installed) see
  zero prompts, also on day one. The script deliberately does not run as
  root: dotfiles and configs must stay user-owned.

### 6.3 opencode

- Skip when `opencode` resolves to a working executable (an
  `-x`-capable lookup in PATH, else `~/.opencode/bin/opencode`).
  An existing install is kept at its own version - pinning governs
  fresh installs only.
- Target detection (same logic as the official installer): os =
  darwin|linux, arch = arm64|x64; x64 additionally checked for AVX2
  (`/proc/cpuinfo` on Linux, `sysctl hw.optional.avx2_0` on macOS) and
  musl (`ldd --version`) on Linux. A baseline or musl target has no
  pinned checksum: report "unsupported CPU/libc variant" as an error.
- Download
  `https://registry.npmjs.org/@opencode%2fcli-<target>/-/cli-<target>-<version>.tgz`
  with the curl policy (7.1) to a temp file under `~/setup-magpie`.
- `sha256()` helper per OS: `sha256sum` (Linux) / `shasum -a 256`
  (macOS) - as `magpie_sha256` in the full scripts. Compare against the
  pinned value for that target. Mismatch: delete the file, retry via
  7.2; final mismatch = error block (download corrupt).
- Extract `package/bin/opencode` -> `~/.opencode/bin/opencode`, chmod
  755. Nothing else from the archive is installed.
- Register PATH (6.6). `say "OK: opencode <version> installed"` - only
  when this run installed it, plus the PATH note when a line was added.

### 6.4 nono

- Skip when `nono` resolves (PATH or `~/.nono/bin/nono`).
- Pinned `NONO_VERSION`. Asset
  `https://github.com/nolabs-ai/nono/releases/download/v<ver>/nono-v<ver>-<rust-arch>.tar.gz`,
  `rust-arch` from `uname -m`: `x86_64` or `aarch64` (Apple `arm64` ->
  `aarch64`). Pinned sha256 per the four targets
  (`{aarch64,x86_64}-apple-darwin`, `{aarch64,x86_64}-unknown-linux-gnu`).
- Same download + checksum + retry policy as opencode (7).
- Extract to a temp dir. The archive layout is not guaranteed - locate
  the `nono` executable from the `tar -tzf` listing (the single regular
  file named `nono`), do not hardcode a path. Move it to
  `~/.nono/bin/nono`, chmod 755. No sudo needed on either OS (Linux
  runs on Landlock, macOS on Seatbelt).
- Gatekeeper note: `curl` does not set the quarantine xattr, so the
  downloaded binary is not prompted; verify once on a real Mac.
- Register PATH. `say "OK: nono <version> installed"`.

### 6.5 OS branches (before the tools)

Ubuntu (Linux):

- Skip the whole apt step when `git` AND `curl` both resolve to working
  executables (WSL preinstalls both - the day-one ask stays cheap and a
  repair never needs sudo at all). Otherwise: `apt-get update` and
  `apt-get install -y -o Acquire::Retries=3 git curl` (the safety net =
  install-if-missing). `dpkg` lock contention is a transient error:
  retried (7.2).
- No other apt packages in this script.

macOS (Darwin):

- curl: system `/usr/bin/curl` always exists. Verify only
  (`command -v curl`), no install, no `OK:` line.
- git: if `command -v git` fails or the Apple shim refuses, install the
  Xcode Command Line Tools unattended:
  1. `touch /tmp/.com.apple.dt.CommandLineTools.installondemand.txt`
  2. `softwareupdate --list`, pick the newest `Command Line Tools for
     Xcode ...` label
  3. `softwareupdate --install "<label>"` (sudo already warm from 6.2)
  4. verify `git --version`
  No Homebrew, no GUI dialog, no rerun pattern. Wi-Fi stalls are handled
  by the retry wrapper; a broken CLT install re-runs cleanly.

### 6.6 PATH registration

Shared helpers, as in the full scripts:

- `rc_add_path <rc> <dir>`: append one `export PATH` line when the dir is
  not mentioned in the rc file yet; a missing final newline is closed
  first, so the append never merges into the file's last line; always
  `export` for the current run. rc file: `~/.bashrc` (Linux) / `~/.zshrc`
  (macOS).
- `fix_bin_path`: for `opencode` and `nono` - when not on PATH but found
  in `~/.opencode/bin`, `~/.nono/bin`, `~/.local/bin`, `/usr/local/bin`,
  `/opt/homebrew/bin`: register via `rc_add_path`. Found nowhere:
  error block (an install step must have lied).
- After installing, both tools are on PATH in the same run, so the
  final launch works without a new terminal.

### 6.7 opencode config (HU LLM3)

Byte-identical block as in the full scripts
(`magpie_opencode_config`): `~/.config/opencode/opencode.json` with the
`hu` provider (baseURL `https://llm3-compute.cms.hu-berlin.de/v1`,
`env: ["HU_API_KEY"]`, openai-compatible package,
`chat_template_kwargs.enable_thinking`) and top-level
`"model": "hu/llm3"` - that is the preselection.
Guard first, repair included: an existing file containing the literal
string `vLLM PIK HPC` - the provider name of a teacher/dev local vLLM
endpoint - is never touched: no write, no `.bak`, one log line, the
step counts as satisfied (the guard short-circuits before the
identical-skip, backup and force-write below). It exists because on
2026-11-18 such a force-write silently destroyed exactly that config
on the course maintainer's machine; students by design have no
pre-existing opencode config, and the course config never contains the
marker, so the guard cannot shadow a course-owned file.
Identical file: skip. Different existing file: copy to `.bak`, then
write. In repair mode (`MAGPIE_REPAIR=1`) the file is ALWAYS rewritten
(foreign content backed up to `.bak` first): a student or their LLM can
break this JSON, the fast-path stat cannot judge content, and a corrupt
config shows up as an opencode quick-fail. No `OK:` line (not a tool),
one log line.

`HU_API_KEY` needs no rc line in this script: section 5 step 3 exports it
for the run, and the launched opencode inherits it. A leftover line from
the full course scripts is harmless.

### 6.8 nono profile (pinned pack version)

The pulled pack IS the sandbox policy, so its version is pinned in the
header block (`NONO_PACK_VERSION`) like the binaries:

- Skip when the installed pack's `package.json` reports exactly the
  pinned version (version read via `sed` on `"version"` - no JSON parser
  dependency).
- Installed but DIFFERENT version (drift, e.g. a student ran
  `nono update` or an older script version pulled): force re-pull at the
  pin - same cure as repair mode.
- In repair mode (`MAGPIE_REPAIR=1`) the skip NEVER applies: force
  re-pull regardless. A half-broken pulled package looks "present" to a
  plain existence check and is a known cause of sandbox quick-fails; the
  re-pull is the cure.
- Pull = `nono pull nolabs-ai/opencode@<pin>` (`--force` when forced),
  wrapped in the retry helper (registry download over Wi-Fi). After a
  successful pull the installed version is verified against the pin - a
  registry that served something else fails the step, not the sandbox.
  Then best-effort `nono pin nolabs-ai/opencode` so a later
  `nono update` cannot drift the policy between course runs (a pin
  failure is only a log line - cosmetic).
- `say "OK: nono profile opencode pulled (<version>)"`.
- Known accepted exposure of the upstream pack (not a course profile
  override): it grants `~/.claude`, `~/.codex`, `~/.npm` read-write and
  reads the macOS login keychain. `~/.npm` is needed at runtime (npm
  installs for opencode providers/plugins).

### 6.9 magpie clone

- Skip when `~/magpie/.git` exists AND `git rev-parse HEAD` resolves.
  If `.git` exists but its `origin` is not the pinned URL, the foreign
  guard below fires. If HEAD does not resolve (interrupted fetch left
  `.git` without a checkout), the clone body re-runs and heals.
- "Foreign content" guard: if `~/magpie` holds entries OTHER than the
  housekeeping files of EITHER course script (both scripts share the
  folder, so the allowlist is identical to setup-magpie.sh's:
  `.git/`, `setup-log.txt`, `setup-help.txt` and `setup-help-profile.json`
  (neither written any more - allowed to stand so older distributed
  copies never block a clone; the `.json` held the rejected-profile dump
  the 2026-11 copies left behind, written exactly by the runs that died
  at the profile step BEFORE any clone), `.setup-finished`,
  `.setup.lock/`, `.keepalive.pid`, `.setup-fullrun-ok` (setup script's
  full-run marker), and the install leftovers `opencode-dl.tgz`,
  `opencode-extract/`, `nono-dl.tar.gz`, `nono-extract/`, `setup-dl-*`
  (the setup script's downloads - a hard-killed run skips its EXIT
  cleanup)), error block
  ("folder exists but is not a magpie clone - move it away or delete
  it"). Under the work-dir layout a fresh `~/magpie` is empty when the
  guard runs (the entry sweep has moved or deleted the legacy names,
  and no own state is written here any more); the allowlist stays as
  the belt-and-braces line for leftovers the sweep could not remove,
  and it is pinned directly as a unit (clone run with every name
  present at once). A foreign file (any other name) still blocks.
- Clone into a directory that still holds files (sweep-proof leftovers,
  repo content of a healed clone - plain `git clone` refuses
  non-empty). `magpie_clone_body` starts with `mkdir -p ~/magpie`: the
  clone step is the only maker of the folder. Every sub-step must survive an interrupted previous
  attempt (a retry re-enters mid-sequence):
  1. `git init` in `~/magpie` (idempotent)
  2. `git remote get-url origin >/dev/null 2>&1 ||` add origin
     `https://github.com/magpiemodel/magpie.git` - never die on
     "remote origin already exists"
  3. branch = `git ls-remote --symref origin HEAD` (second field of the
     `ref:` line, strip `refs/heads/`)
  4. `git fetch origin +refs/heads/<b>:refs/remotes/origin/<b>` (full
     history - magpie tooling may use git metadata)
  5. `git checkout -B <b> origin/<b>` (`-B`, not `-b`: an interrupted
     run may have left the branch half-created)
- Stalled-transfer guard on both remote calls:
  `GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30`.
- Wrapped in the retry helper. `say "OK: magpie cloned"`.

### 6.10 Sandbox smoke test (setup path, gates the marker)

Last step before the marker. One cheap session that proves the real
thing, inside the sandbox:

```
cd ~/magpie
nono run --profile nolabs-ai/opencode --allow-cwd --silent -- \
  sh -c 'command -v opencode >/dev/null && test -r "$HOME/.config/opencode/opencode.json" && test -n "$HU_API_KEY"'
```

It checks, under the actual profile: nono boots the profile at all
(WSL without Landlock and broken pulls die here), `opencode` is on the
sandbox PATH, the config is readable through the profile allow-list,
and `HU_API_KEY` survives into the sandbox (if a future nono filtered
env, opencode would silently lose the HU provider - catch it before
writing the marker). No network, no HU call, about one second. Output
goes to the log.

Wrapped in the retry helper (7.2) and the pass rule (7.3); a reproducible
failure names the step `sandbox smoke`. Only after it passes: write
`~/setup-magpie/.setup-finished` (timestamp + versions, content per 6.1).

### 6.11 Launch (both paths)

Never `exec` - opencode runs as a child so the script can judge the
outcome:

1. Stop the sudo keep-alive (6.2) - nothing sudo-warm may exist while
   opencode runs. Then `cd ~/magpie`. Ensure the resolved
   opencode/nono binary dirs are on
   PATH: the setup path already exported them (6.6); the fast path
   exports the two dirs it resolved - without this, a session that
   never sourced its rc file would find the tools in the checks but
   fail to launch them by name. One screen line right before the
   launch - `OK: setup complete - starting opencode in ~/magpie` - on
   BOTH paths: the fast path is otherwise silent until opencode's own
   UI appears, so a student cannot tell "ready" from "hanging".
2. Launch with explicit fds: `nono run --profile nolabs-ai/opencode
   --allow-cwd -- opencode >&4 2>&4` (stdin is already the real
   terminal; `main`'s own
   fd 1/2 stay the log - no fd restore is needed thanks to the scoped
   redirect, 5). Remember the start time, `wait`. The child gets this
   run's environment (`PATH`, `HU_API_KEY`) and `~/magpie` as workdir
   (the profile makes it read-write). Network is open in the pulled
   profile, so the HU endpoint is reachable - verifiable only on HU
   network/VPN; check that `opencode models` lists `hu/llm3`.
3. Append `launch: exit <code> after <secs>s` to the log.
4. Exit 0, or run time at or above 15 s: normal session, done, exit 0.
5. Non-zero exit within 15 s: the sandbox never came up (broken profile,
   kernel update without Landlock, deleted binaries). Heads-up (fd 4):
   `[HH:MM:SS] - startup problem, repairing automatically, about 1 min`,
   then re-run the setup path once in a fresh process:
   `MAGPIE_REPAIR=1 MAGPIE_PASS=2 exec bash "$0"` when `$0` is a file,
   else the same in-process. All install steps skip by local checks and
   no sudo is asked (6.2) - the repair is force-re-pull + config rewrite
   + smoke test; the smoke test (6.10) re-verifies; then launch again.
   - `MAGPIE_REPAIR=1` never re-repairs: a second quick-fail is proven
     reproducible -> failure verdict, exit 1. `MAGPIE_PASS=2` means any setup
     failure inside the repair goes straight to its retries and the
     failure verdict - the script never runs a third pass.
   - Known false trigger: the student quits opencode within 15 s with a
     non-zero exit. Cost: one repair round (profile re-pull + smoke,
     ~1 min), then opencode opens again. Accepted.

The sudo timestamp and the keep-alive loop survive the repair exec just
like they survive pass 2 (tty cache + pidfile, 6.2/7.3) - the loop is
only stopped when a launch actually starts (6.11). The repair counts as
a setup run.

## 7. Error handling

### 7.1 Network policy (every download)

`curl -sS -fL --retry 4 --retry-delay 5 --retry-all-errors
--connect-timeout 15 --max-time 900`, plus `-C -` resume for the archives.
`-sS`: no progress spam in the log, real errors still visible. curl
retries transient HTTP/TLS/DNS errors itself. A checksum mismatch after
a resumed download means corruption: delete, full re-download.

### 7.2 Step-level retry

`retry 3 <cmd...>`: run; on ANY non-zero exit wait 10 s and retry, then
wait 30 s and retry (3 attempts total). Not network-specific - covers
dpkg/apt lock contention, half-written state, registry 500s, flaky
`softwareupdate`. Steps are self-cleaning (temp file + `mv`, `rm -rf`
before extract) so a repeat attempt never trips over the last one's
wreckage. All attempt lines go to the log only.

### 7.3 Second pass in a fresh process ("reproducible" rule)

When a step still fails after 7.2:

1. Log the failure.
2. Print one calm heads-up (fd 4):
   `[HH:MM:SS] - something failed, retrying automatically in N s`
   (N = `MAGPIE_PASS_SECS`, default 30).
   `sleep N`. No error block - yet.
3. `MAGPIE_PASS=2 exec bash "$0"` when `$0` is a readable file (run as
   `bash magpie-opencode.sh`); otherwise run a second pass in-process
   (paste case).
4. The fresh process: re-enters normally, the fast path declines (no
   marker yet), skip-if-done steps pass by local check - pass 2 resumes
   effectively at the failed step. The warm sudo timestamp survives
   (sudo caches against the tty), the keep-alive loop survives the exec
   (detected via pidfile, not re-spawned), the lock is re-adopted via
   the self-pid rule (5), and the EXIT trap is re-armed. The log
   appends.
5. `MAGPIE_PASS=2` is never re-passed: pass 2 is the final verdict. A
   failure there (same step = proven reproducible; different step = it
   got its own 7.2 retries first) prints the failure verdict and exits 1.
   Worst-case budget before a report: ~5 minutes.

### 7.4 Failure verdict (only output on failure)

Screen only (fd 4): no file, no feed, no copy-paste frame, no LLM
prompt (the full scripts dropped that flow, and this script never had a
feed to carry a block anyway):

```
SETUP FAILED (twice, reproducible): <step>
  <hint line, when the step passed a hint>
  system: <PRETTY_NAME or sw_vers> | <arch>
  last log line: <last line of ~/setup-magpie/setup-log.txt>
  everything else: ~/setup-magpie/setup-log.txt
```

The marker is not written, so the next run starts on the setup path
again - rerunning remains the universal fix.

The hint is a line of the verdict when it fits the failure:

- Linux + `sandbox smoke` failed: "If the error mentions Landlock:
  close Ubuntu, open Windows PowerShell, run `wsl --update`, wait for
  it, reopen Ubuntu, run this file again." (Old WSL kernels lack
  Landlock - the most common cause.)
- macOS + the CLT step failed: "Run `softwareupdate --list`, then run
  this file again."
- Any download step failed: "Room Wi-Fi may need a browser login: open
  any website in your browser first, or use your phone hotspot, then
  run this file again."

### 7.5 sudo failures

Not part of the retry machinery. sudo's own 3 tries, then the "try
again" line, loop cap 6, then the failure verdict (reason:
"password was never accepted").

## 8. Verification plan

The script must stay sourceable for tests (definitions above the entry
call, guarded by `MAGPIE_SOURCED` as in the full scripts).

Offline harness (fake `$HOME`, stub `curl/apt/git/softwareupdate/sudo/df/
tar/nono/opencode`), like the existing
`.tmp/test-path-export.sh`:

- syntax: `bash -n`, bash32 guard (no bash4+ constructs, and none of
  the 2's banned idioms - double bracket, dollar-RANDOM, process
  substitution - run on the script and the harness; a per-idiom
  fixture self-test pins the guard pattern itself, so narrowing it
  goes red); shellcheck when
  available (bash mode).
- entry guard: unwritable `$HOME` (cannot create `~/setup-magpie`, and
  neither dir is created) -> the
  failure verdict is the only output on screen (fd 4; the log file is
  impossible here) and no log dir is left behind; a low-disk abort on
  a WRITABLE HOME proves the entry creates only the work dir -
  `~/magpie` comes with the clone step alone; the `df` probe target is
  pinned on the source text (the stub answers path-blind).
- fast path: table of marker-present/absent x each check present/broken;
  broken install with marker falls into setup path;
  `MAGPIE_FORCE_SETUP`/`MAGPIE_REPAIR` both respected (repair must NOT
  take the fast path).
- checksums: fake archive accepted on match, retried and blocked on
  mismatch.
- download policy pinned on the source text: `curl -sS -fL --retry 4
  --retry-delay 5 --retry-all-errors`, `--connect-timeout 15
  --max-time 900`, `magpie_curl -C - -o` - a quiet flag drop would keep
  the behavioural download tests green while course downloads lose
  their retries and stall guard.
- retry helper: transient failure (2 fails then 0) passes silently;
  persistent failure (3 fails) triggers pass 2; pass 2 failure prints
  the failure verdict and exits 1; `MAGPIE_PASS` never reaches 3.
- keep-alive: loop spawned once; detected through the pidfile on pass 2;
  killed on the OWNER's exit AND before launch (the stub `nono run`
  records whether the pidfile was still alive at the launch instant);
  a non-owner exit ("already running", no lock ever taken) leaves the
  loop and its pidfile untouched; a second start while the pidfile pid
  is alive never stacks a second loop (same pid kept, owner exit stops
  the one loop).
- sudo loop: stubbed `sudo -v` failing N times then succeeding - loop
  must not print the failure verdict for N < cap; failure verdict at cap.
- sudo timing: day-one setup with git+curl present -> ZERO sudo
  invocations (no upfront ask, no prompt); the apt/CLT bodies keep the
  warm-up loop for the machines that need them.
- nono pack pin: pull always carries `@<pin>`; post-pull version
  verified; drift (installed != pin) -> fast path declines, setup
  force-re-pulls at the pin; `nono pin` called after every successful
  pull. A registry that hands back a stale pack DESPITE the pinned ref
  is a failure, never a silent pass: the wrong version is logged and
  the step fails at the pass cap ("nono profile pull"). Pinned by the
  suite's wrong-version scenario (stub knob `STUB_NONO_PULL_WRONG_VER`).
- PATH: dedupe over two runs; both tools visible in the same run
  (final launch uses a stub `nono` that records its PATH); an rc whose
  last line has no final newline gets the new PATH line on its own
  line (no merge).
- smoke test: stub `nono run` exits 1 -> retries, pass 2, failure verdict, and
  the marker is NOT written; exits 0 -> marker written.
- launch quick-fail: stub `nono run` exits non-zero in <15 s -> exactly
  one repair run (`MAGPIE_REPAIR=1 MAGPIE_PASS=2`), then relaunch; the
  repair must actually run the steps - assert `nono pull --force` and
  the config force-write happened, and that the repair proceeds despite
  the lock/keep-alive already being owned (self-pid re-adoption after
  exec, and in-process); quick-fail inside repair -> failure verdict, no
  third attempt. Stub exits 0, or exits non-zero after >=15 s -> quiet
  exit 0, no repair.
- config: identical skip; foreign file -> `.bak` + write; in repair
  mode -> `.bak` + rewrite even when identical; `vLLM PIK HPC` marker
  in an existing file -> untouched, no `.bak`, repair included; the
  course config itself carries no marker.
- clone: skip on resolvable HEAD; heal of `.git` without commits;
  foreign `origin` URL -> error block; git-init path with stubbed
  ls-remote/fetch; re-entry with pre-existing `origin` remote and
  half-created branch must succeed (idempotent sub-steps); dir holding
  only the script's own files (incl. install leftovers) -> proceeds;
  dir with one foreign file -> error block; the allowlist is pinned
  VERBATIM-identical to `setup-magpie.sh`'s by a cross-file comparison
  in both suites.
- disk: stubbed `df` below 4 GB -> failure verdict, no install attempt;
  above -> untouched.
- lock: live second instance -> single heads-up line, exit 0,
  no installs; stale lock (dead pid) -> reclaimed silently - asserted
  from OUTSIDE the exit code (no heads-up on screen, reclaimed lock
  released on the owner's exit: an early `exit 0` inside the lock
  function must not skip the proof);
  pass-2 exec and in-process second pass -> lock seen as self-owned,
  setup continues (must NOT exit with "already running").
- traps: SIGINT mid-setup (lock held = owner) -> EXIT trap ran ->
  keep-alive pid gone (`kill -0` fails), lock dir removed.
- pinned block: placeholder value present -> instant failure verdict,
  nothing else runs; all filled -> no message.
- heads-up lines: printed exactly once per step that RUNS, zero for
  skipped steps (count equals executed steps).
- work dir: log + marker land under `~/setup-magpie`; an old-layout
  machine (state seeded in `~/magpie`, markers only at the old
  positions) migrates at entry - the moved finish marker drives the
  fast path, the old log content survives, junk is gone from
  `~/magpie`; the conflict semantics of THIS copy of `magpie_sweep_legacy`
  are pinned as a unit (append on log conflict, work-dir copy wins on
  marker conflict) - the two scripts' identical-semantics claim must
  hold per script, not per spec. No help file any
  more - the verdict names the log instead of writing a copy, and it
  quotes the log's last line on screen: `last log line: ...`.

Live tests (must): WSL Ubuntu end to end; Intel Mac + Apple Silicon Mac
each once (CLT unattended install, Gatekeeper behavior of the curl'd
binaries, zsh rc). HU provider answer: one machine on HU network.

## 9. Teacher to-do before the session

0. No student handout for this script (the old `SETUP.md` flow does not
   apply): the screen output is the handout. Students know one command,
   day one and every day: `bash ~/magpie-opencode.sh`.
1. Nothing to fill in by hand: versions and checksums were computed at
   implementation time (4). Before distributing, run the file once with
   `MAGPIE_FORCE_SETUP=1` - the placeholder guard proves the pins are
   real, the live tests prove the checksums match.
2. Run the live tests in 8.

Day-one expectation on screen, for projecting: heads-up lines per real
step, `OK:` lines (a password prompt only if apt/CLT must run), one
`OK: setup complete - starting opencode in ~/magpie`, then
opencode opens inside `~/magpie` with the HU model selected.
