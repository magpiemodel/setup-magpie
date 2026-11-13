# setup-magpie.sh - spec (unified day-one course setup)

Status: implemented in setup-magpie.sh (tests: tests/test-setup-magpie.sh,
460 assertions (461 when shellcheck is present), all green on a Linux
x86_64 dev host). Date: 2026-11-13.

## 1. Purpose

`setup-magpie.sh` is the students' ONE day-one file: download it, run
`bash setup-magpie.sh` on macOS (Apple Silicon or Intel) or in WSL Ubuntu,
and the machine ends up ready for MAgPIE - git, opencode + nono + HU
config, the course tool chain (R, gfortran, pandoc, TinyTeX, GAMS +
course licence), the pinned nono profiles, a `~/magpie` clone, the
restored renv R library, a checks block (unsandboxed + inside the
sandbox gate), and ONE completed full default run (solve + default
output scripts) INSIDE the course sandbox. Exit 0 guarantees all of it.

It replaces `setup-ubuntu.sh` and `setup-macos.sh` (see 3) and is built
on the skeleton of `magpie-opencode.sh`: the same helpers, the same
error model, the same file layout under `~/magpie`. `magpie-opencode.sh`
stays the daily launcher; the two scripts never clash (see 2).

Support model unchanged from the old course scripts: the teacher watches
the live ntfy feed under each student's animal code name, the `##` help
block feeds the students' LLM, students self-heal.

## 2. Design decisions

- One file, both OSes. Branch on `uname` (Darwin | Linux), like
  `magpie-opencode.sh`. Valid POSIX sh from line 1, run via `bash`
  only - no `[[`, no arrays, no `local`,
  no `$RANDOM`, no process substitution.
- The ntfy feed and the animal code name are KEPT (unlike
  `magpie-opencode.sh`): the teacher watches the feed on course day.
  The handle is `Animal+3digits` in `~/.magpie-course-handle`, picked
  from `/dev/urandom` (dash has no `$RANDOM`). First creation is atomic
  (noclobber): two concurrent first runs converge on one name. It prints
  the "NOTE IT DOWN" box and waits for Enter on `/dev/tty`.
- All state lives under `~/magpie` with EXACTLY the file names
  `magpie-opencode.sh` expects (`setup-log.txt`, `setup-help.txt`,
  `.setup.lock/`, `.keepalive.pid`, `opencode-dl.tgz`,
  `opencode-extract/`, `nono-dl.tar.gz`, `nono-extract/`).
  `.setup-finished` is `magpie-opencode.sh`'s finish marker ONLY -
  this script never writes it, so running both scripts side by side
  stays consistent. `.setup-fullrun-ok` (full-run marker, holds the
  verified run folder path) is THIS script's own file - in the clone
  guard allowlist, never cleaned.
- Extra downloads (GAMS, R, gfortran, pandoc) go under `~/magpie` named
  `setup-dl-*` and are deleted on success AND in the EXIT trap - a
  crash never leaves foreign files behind. The clone guard's own-file
  allowlist includes `setup-dl-*`. Leftover or partial magpie RUN
  folders (`output/default_*`) are NEVER cleaned or touched.
- No Homebrew anywhere (Homebrew 5 refuses Intel Macs). macOS R /
  gfortran / pandoc / GAMS are pinned `.pkg` downloads, sha256-checked,
  installed with `sudo installer -pkg ... -target /`, each
  skip-if-done. Xcode CLT installs unattended via `softwareupdate`.
- Sudo is asked only inside steps that actually run, through the
  `magpie-opencode.sh` warm loop + keep-alive. The keep-alive is
  stopped BEFORE the sandbox gate: no warm sudo credential may exist
  while a sandboxed process runs.
- Errors are only reported when reproducible (the `magpie-opencode.sh`
  model): in-step retries, then one full second pass in a fresh
  process; only a failure repeating in pass 2 prints the `##` help
  block and exits 1. This REPLACES the old course scripts' "continue
  after FAIL and keep installing" behaviour.
- The run ends with: unsandboxed checks -> all PASS: sandbox gate
  (`nono run --profile magpie-profile -- ... bash <thisfile>
  --check-only`) -> full default run inside the same sandbox (see 6.10)
  -> next steps -> feed "run finished" -> exit 0.
  Any FAIL (step-level, check, or gate): feed the FAIL line(s), print
  the help block, exit 1.
- The full default run (about 40 min on the students' machines) is part
  of the exit-0 guarantee. Escape hatch: env `MAGPIE_FULL_RUN=0` skips
  it (screen + feed note, checks line SKIP, no marker - setup still
  exits 0). The run gets ONE attempt: no step retries, no second pass;
  any failure goes straight to the help block, exit 1 - the next
  manual rerun redoes it (the marker stays unwritten until verified).
- Deterministic data folders: `MADRAT_MAINFOLDER=$HOME/.madrat`
  (madrat mainfolder, cache lives under it) and
  `RENV_PATHS_CACHE=$HOME/.cache/R/renv` are fixed (not
  env-overridable), exported into the run, written as grep-guarded rc
  lines (`magpie_register_caches`), and passed explicitly into every
  sandboxed child - the nono profile grants read+write in exactly
  these folders.
- Disk guard has two tiers (from the old scripts, env-overridable,
  raised for the full run): below `MAGPIE_DISK_ABORT_GB=9` the help
  block aborts; below `MAGPIE_DISK_WARN_GB=18` a warning goes on
  screen and to the feed.
- `HU_API_KEY`: exported for the run AND written as one grep-guarded
  rc line - there is no launcher in this script, students may start
  opencode later from a fresh terminal (the real credential is
  injected by nono).
- magpie is cloned by this script (`git init` + remote + `ls-remote` +
  fetch + `checkout -B`, the non-empty-directory-safe pattern from
  `magpie-opencode.sh`), so the "next steps" no longer include cloning.

## 3. Files

- `setup-magpie.sh` - student deliverable (standalone, both OSes)
- `spec-setup-magpie.md` - this file
- `tests/test-setup-magpie.sh` - offline harness (Linux x86_64 + AVX2
  host - the pinned GAMS/opencode builds - else exit 77 skip)
- `magpie-opencode.sh`, `tests/test-magpie-opencode.sh` - bug fix
  (round 4, maintainer-approved): EXIT cleanup is gated on lock
  ownership, so a non-owner exit no longer kills the running owner's
  sudo keep-alive; `spec-magpie-opencode.md` - cross-references and the
  cleanup wording updated; `README.md` - untouched
- `setup-ubuntu.sh`, `setup-macos.sh`, `spec.md` - REMOVED, superseded
  by `setup-magpie.sh` and this spec.

## 4. Pinned block (top of file, machine-filled - not hand-edited per course)

Every line starts at column 0 (`^VAR=`) so the test harness and
re-pinning can sed them; the placeholder guard aborts instantly while
any pin is empty or `TBD`.

- From `magpie-opencode.sh` (verbatim): `OPENCODE_VERSION` 2.2.7 + four
  target shas, `NONO_VERSION` 0.81.0 + four target shas,
  `NONO_PACK_VERSION` 0.4.2.
- From the old scripts: `GAMS_VERSION` 54.6.1 -
  `GAMS_URL_LINUX_X64` + `GAMS_SHA256_LINUX_X64`
  (ac198c62...fd34eb1), `GAMS_URL_DARWIN_ARM64` +
  `GAMS_SHA256_DARWIN_ARM64` (0cb71b96...ed1223b),
  `GAMS_URL_DARWIN_X64` + `GAMS_SHA256_DARWIN_X64`
  (f02a3392...1e8276).
- NEW macOS pins (verified live 2026-11-12, sizes cross-checked against
  HEAD `content-length`):
  - `GFORTRAN_VERSION=14.2`, `GFORTRAN_URL=
    https://mac.r-project.org/tools/gfortran-14.2-universal.pkg`
    (universal), sha256 `ec462d465f093eeee0623d2b5d327bd1038313b985034b766462957e36d7aadd`.
  - `R_VERSION=4.6.2`, per-arch pkgs (no universal pkg is published):
    `R_URL_DARWIN_ARM64=.../sonoma-arm64/base/R-4.6.2-arm64.pkg` sha256
    `a678b4db1fcd71b1b1cc58edcfa4a8d36ee012a02659dde9eab9366e93571157`;
    `R_URL_DARWIN_X64=.../big-sur-x86_64/base/R-4.6.2-x86_64.pkg` sha256
    `aa9b1dba09cc69710571ad93efba26a9bcb5a0098543dadc4bb8e419a423195e`.
  - `PANDOC_VERSION=3.14`, per-arch pkgs:
    `PANDOC_URL_DARWIN_ARM64=https://github.com/jgm/pandoc/releases/
    download/3.14/pandoc-3.14-arm64-macOS.pkg` sha256
    `33f1049a362f782b2f2ee81d99d110d0283047312650ce1ab7f5c9116ec9ca51`;
    `PANDOC_URL_DARWIN_X64=...x86_64-macOS.pkg` sha256
    `145a39969291a8af79fe81037be3eb6e56511f0056b4dfd562571312f0b9b7c7`.
- Re-pin per asset: `curl -fsSL <url> | sha256sum` (macOS:
  `shasum -a 256`). New versions: check
  https://cran.r-project.org/bin/macosx/ (R),
  https://mac.r-project.org/tools/ (gfortran),
  https://github.com/jgm/pandoc/releases/latest (pandoc), the GAMS CDN
  distributions folder, and the opencode npm registry / nono releases.

The TEACHER SECTION below the pins holds `STATUS_URL` ("" disables the
feed) and `magpie_licence_text()` - the single place the teacher pastes
`gamslice.txt` (placeholder still inside = early warning on screen +
feed, nothing is written).

## 5. Script skeleton and order of operations

Same scoped-redirect entry as `magpie-opencode.sh`: the real terminal is
saved on fd 4, the whole main run goes to `~/magpie/setup-log.txt`,
screen output only through `magpie_say`. The `--check-only` child (env
`MAGPIE_CHECK_ONLY=1` or argument) is branched BEFORE the log
redirect - it writes no log, takes no lock, runs no installs.

Order: OS detect (`MAGPIE_OS`, `MAGPIE_RC` = `~/.zshrc` / `~/.bashrc`) ->
`HU_API_KEY` export -> check-only branch (greet + checks + exit) ->
greet + feed "setup: start" -> root guard -> pin placeholder guard -> disk
check (two tiers) -> licence placeholder check (warn early, reaches the
feed before the long installs) -> take the mkdir lock (+ traps; the lock
OWNER's EXIT cleanup also removes `setup-dl-*` - a second window that
exits with "already running" never touches the first run's state) -> `step_os_base` (apt git/curl only
if missing; CLT unattended on macOS) -> opencode install (pinned npm
tgz, AVX2/musl checks) -> nono install (pinned GitHub tarball to
`~/.nono/bin`) -> PATH fixes -> opencode config -> HU key rc line ->
cache folders + rc lines -> OS tool steps -> TinyTeX + tex PATH -> GAMS
install + PATH -> licence -> nono pack pull/pin -> `magpie-profile`
build -> magpie clone -> renv library restore (6.9) -> checks -> (green:
stop keep-alive, sandbox gate, full default run (6.10), next steps, feed
"run finished", exit 0). Every slow step that RUNS gets one
`[HH:MM:SS] - installing ...` heads-up; installs print `OK:` lines.
The keep-alive is stopped once, before the gate; no warm sudo exists
while the gate child OR the full run sandbox executes.

## 6. Steps

### 6.1 OS base (from `magpie-opencode.sh`, verbatim)

Linux: skip when git AND curl resolve; else `apt-get update` + install
git curl (sudo warm inside). macOS: system curl verified; Xcode CLT via
`touch installondemand` + `softwareupdate --list` (newest label) +
`sudo softwareupdate --install` - no GUI, no rerun dance.

### 6.2 opencode, nono, opencode config, nono pack (verbatim)

Identical to `magpie-opencode.sh` 6.3/6.4/6.7/6.8 (pinned archives,
checksum, extract, `~/.opencode/bin`, `~/.nono/bin`, PATH registration,
HU LLM3 config with `.bak` protection, pack pull at
`nolabs-ai/opencode@$NONO_PACK_VERSION` + drift force-re-pull + `nono
pin`). Feed lines "setup: opencode installed" / "setup: nono installed"
/ "setup: nono profile pulled" at the old milestones.

### 6.3 Course tools - Linux

One step, one apt call: base tools (`git wget zip unzip r-base pandoc
build-essential cmake gfortran`) plus the full -dev library list from
the old `setup-ubuntu.sh` (gdal, libcurl, fontconfig, freetype,
fribidi, gdal, git2, glpk, harfbuzz, jpeg, netcdf, png, poppler-cpp,
cairo, ssl, tiff5, udunits2, xml2, uv1, pari-gp, qpdf),
`Acquire::Retries=3`, `magpie_sudo_warm` inside. Skipped when R >= 4.3
AND pandoc are already present. Both apt calls (also the git/curl one
in 6.1) carry `-o DPkg::Lock::Timeout=120`: the old feed's biggest
Linux failure cluster (`FAIL apt install of libraries`) is the dpkg
lock held by WSL's unattended-upgrades - far past the step-retry
waits. apt now waits up to 2 min per attempt for the lock
(option since apt 1.9.11, i.e. Ubuntu 20.04+ = the WSL floor).

### 6.4 Course tools - macOS

Three pinned-pkg steps, each skip-if-done: gfortran (skip: `gfortran`
on PATH or `$MAGPIE_GFORTRAN_DIR/bin/gfortran`, default
`/usr/local/gfortran` - variable so the harness can fake the pkg
target), R (skip: `Rscript` >= 4.3), pandoc (skip: `pandoc` on PATH).
The gfortran pkg target is NOT on PATH by default: after skip OR
install, `magpie_register_gfortran` puts `<dir>/bin` in the rc + this
run's PATH, or renv restore compiles and the sandboxed children never
find gfortran. Download `setup-dl-<name>.pkg` -> `magpie_sudo_warm` ->
sha re-check right before `sudo installer -pkg ... -target /` (root
never reads a file that changed after verification) -> remove the
download. Checksum mismatch blocks BEFORE any sudo call. GAMS macOS
uses the same helper. The magpie-profile read list keeps the literal
`/usr/local/gfortran` - the sandbox policy always names the real
system path.

### 6.5 TinyTeX + tex PATH

Skip only when a working tex exists: `magpie_texbin()` output
non-empty (`command -v tex`, else the first `~/.TinyTeX/bin/*/`
holding an executable tex). A bare `~/.TinyTeX` DIRECTORY is NOT
enough - a run killed mid-install left exactly the old feed's
permanent `FAIL tex not found` state; an existing incomplete dir is
`rm -rf`-ed and the install reruns.
`magpie_texbin()` / `magpie_register_tex()` from the old scripts: the
registered dir goes through `rc_add_path` (rc line + export into this
run) so the checks and the gate see tex without a new terminal.

### 6.6 GAMS + licence

Pinned download per OS/arch (see 4). Linux: self-extractor run inside
`~/gams` with the sha256 RE-checked right before the exe runs; x86_64
only (ARM-WRL = clean feed-reported help block, by design). No
gamsinst. macOS: `sudo installer -pkg`. GAMS PATH registered via
`rc_add_path`. Licence (from the old scripts, merged):
Linux `~/gams/gams*_linux_x64_64_sfx/gamslice.txt` ("rerun" note + feed
line when the GAMS dir is missing yet), macOS
`~/Library/Application Support/GAMS/` (dir chmod 700), file mode 600,
an existing file is never overwritten. GAMS reads it from there - no
license env var anywhere.

### 6.7 magpie-profile + sandbox gate

`~/.config/nono/profiles/magpie-profile.json`, extends
`["opencode"]`. Read list: Linux `$HOME/gams` + `$HOME/.TinyTeX`;
macOS `/Library/Frameworks/GAMS.framework`, `/Library/Frameworks/
R.framework`, `/usr/local/gfortran`, `$HOME/.TinyTeX`, the licence
dir. On both OSes the read list also holds the two data folders,
and the write list is exactly `$MADRAT_MAINFOLDER` (`$HOME/.madrat`) +
`$RENV_PATHS_CACHE` (`$HOME/.cache/R/renv`). The full run downloads
input data into the run folder (`gms::download_distribute`); the
madrat mainfolder is the pinned cache for any madrat read, the renv
cache fills on renv restores.
The folders are created by `magpie_register_caches` before any
sandboxed child runs (write rules need existing paths). `nono profile
validate` must pass before install; an existing different file is kept
untouched. After the checks are green and the keep-alive is stopped,
the gate reruns the checks inside the sandbox:

```
nono run --profile magpie-profile -- env MAGPIE_CHECK_ONLY=1 \
  PATH=<texbin>:$PATH MADRAT_MAINFOLDER=... RENV_PATHS_CACHE=... \
  bash <thisfile> --check-only
```

The child: greet + checks only, feed label "sandbox check result",
exit code = checks result, no lock/sudo/tee/installs -
recursion-proof. Gate failure goes through the retry + pass-2 model
(landlock hint on Linux).

### 6.8 magpie clone

`magpie_clone_body` / `magpie_clone_ok` / `magpie_clone_magpie` from
`magpie-opencode.sh` 6.9, incl. foreign-dir / foreign-origin guards and
the own-file allowlist (magpie-opencode's full list, incl. its
`.setup-finished` marker - tolerated, never written here - extended
with `setup-dl-*` and `.setup-fullrun-ok`).

### 6.9 renv library restore

Runs right after the clone. Skips (log only) when `~/magpie/renv.lock`
is missing or when the library already loads - the load test is
exactly the checks' one (`cd ~/magpie` subshell,
`Rscript -e 'suppressMessages(library(lucode2));
suppressMessages(library(gms))'`, helper `magpie_renv_lib_ok`).
Otherwise, inside `~/magpie`: bootstrap `renv` via
`Rscript -e 'source("renv/activate.R")'` when plain Rscript cannot
`requireNamespace("renv")` (magpie's shipped activate.R, renv 1.2.4,
never asks anything), then
`Rscript -e 'renv::restore(prompt = FALSE, restart = FALSE)'`.
Wrapped in `magpie_retry 3`, failure -> `magpie_step_failed "renv
restore" "wifi"`. Real restores feed "setup: renv restored"; progress
heads-up "about 5-15 min". Fills `$RENV_PATHS_CACHE`, so the sandboxed
run-folder renv restores (6.10) only copy from the cache.

### 6.10 full default run (sandboxed)

Runs after the gate, before the next steps. `MAGPIE_FULL_RUN=0`:
screen + feed note, return 0, no marker. Skip when the marker
`~/magpie/.setup-fullrun-ok` (contains the run folder path relative to
`~/magpie`, e.g. `output/default_...`) points at a folder that still
holds all verification artifacts. Otherwise ONE sandboxed attempt
(macOS wrapped in `caffeinate -is`):

```
(cd ~/magpie && nono run --profile magpie-profile -- \
  env MADRAT_MAINFOLDER=... RENV_PATHS_CACHE=... \
      PATH=<gamsdir>:<texbin>:$PATH \
  bash -c 'cd "$HOME/magpie" && \
           Rscript start.R runscripts=default.R submit=direct')
```

Feed "setup: full run start" before, heads-up "about 40 min, keep the
laptop plugged in and awake". The command's stdin gets two `n` lines:
they answer `start.R`'s possible "Update now?" and `fixDeps` prompts
with "no" - auto-updating would drift from the restored lockfile, and
an EOF stdin would crash `gms::getLine` (empty `readLines` ->
`logical(0)` in `&&`). ONE attempt - no retry, no pass 2.
`start.R` runs the selected script through `sys.source` + `try` (a
failing run is only a warning, exit code stays 0), so SUCCESS IS
DECIDED BY ARTIFACTS: a NEW `~/magpie/output/default_<timestamp>`
folder (pattern pinned from magpie master: `cfg$results_folder <-
"output/:title::date:"` with `:date:` = `_%Y-%m-%d_%H.%M.%S`, title =
`default`), different from the newest complete folder that existed
before the run, containing `fulldata.gdx` + `full.lst` (the run-folder
`submit.R` - copied from `scripts/run_submit/submit.R` - stops without
`fulldata.gdx`; `full.lst` is the GAMS listing) plus `report.rds` +
`report.mif` (written by `scripts/output/rds_report.R`, the last
script of the default postprocessing `cfg$output <- c("output_check",
"extra/disaggregation", "rds_report")`, which the run-folder
`submit.R` runs automatically via `sys.source("output.R")` - no extra
`output.R` call needed). Non-zero sandbox exit fails regardless of
artifacts. Any failure: `magpie_fail "full magpie run (check the run
folder under ~/magpie)" "wifi"`, exit 1. Verified success writes the
marker, prints the OK line and feeds "setup: full run finished".
Partial/failed run folders stay where they are (decision: never
clean).

## 7. Error handling (from `magpie-opencode.sh`)

- Network: `curl -sS -fL --retry 4 --retry-delay 5 --retry-all-errors
  --connect-timeout 15 --max-time 900`, `-C -` resume, intact-temp skip,
  checksum mismatch = delete + retry.
- Step retry 3x (10 s / 30 s waits), then pass 2 in a fresh process
  (`MAGPIE_PASS=2 exec bash <self>`; lock self-re-adoption, warm sudo
  timestamp survives). Pass 2 failure = the `##` help block, exit 1.
  Never a third pass.
- `magpie_fail` additionally feeds `setup: FAIL <step>` before exiting.
  The help block = beginner prompt lines + `System: <sys> | <arch> |
  code name: <handle>` + (`FAILED STEP (twice, reproducible): <step>`
  for step failures, the results list for check failures) + last 25 log
  lines + the per-hint lines (landlock/clt/wifi/sudo). Saved to
  `~/magpie/setup-help.txt`, framed between `##` lines.
- sudo: blind retry loop, cap 6, keep-alive only after a real prompt.

## 8. Checks (`magpie_run_checks`, POSIX rewrite of the old block)

Results accumulate in a newline-separated string (no arrays):
`gams` (found via PATH or the per-OS locations, run in a temp dir;
banner must match `license is valid|licensee` - GAMS 54 + legacy
wordings), `git >= 2.23` (integer compare), `Rscript >= 4.3`,
`pandoc`, `tex`, the `renv` library check (lucode2+gms via a
`cd ~/magpie` subshell) ONLY when `~/magpie/renv.lock` exists -
otherwise the line reads SKIP, and the `full run` line:
`MAGPIE_FULL_RUN=0` -> SKIP (skipped via MAGPIE_FULL_RUN=0); no
marker -> SKIP "starts at the end of this setup" (first runs must not
FAIL here - the step enforces completion); marker present -> run
folder + artifacts verified: PASS, else FAIL "full run artifacts
missing - rerun this file" (delete the marker and rerun to have the
step redo the run). The full run line is cheap and read-only (marker
+ file tests) - it also runs in the sandbox gate child. The block
prints to screen, goes to the feed as "check result" (or "sandbox
check result" in the child), and any FAIL line ends the run (help
block + exit 1; in the child: exit non-zero for the gate).

## 9. Feed protocol (topic `https://ntfy.sh/magpie-course-cb3363c15a75`)

Every message: `<handle> | <OS> <arch> | v<hash> | <text>` (text may
be multi-line), `curl -m 5 --data-binary @-` (the only form ntfy
decodes), never fails the caller. `v<hash>` = first 12 sha256 hex of
this file, computed at entry (uname-based shasum/sha256sum, "unknown"
if the tools are missing): an agent maps hash -> build, an unknown
hash = truncated/edited download. Every body passes `magpie_sanitize`
(one PII choke point inside `magpie_report`): $HOME -> `~`, hostname
-> `HOST`, username -> `USER` (order: home, host, user). Secrets
never reach the log by design: sudo reads the password from the tty
only, the licence text is written to its file only, HU_API_KEY is the
literal placeholder here. Sanitizing third-party output is
best-effort; handles stay pseudonymous.

Milestones: "setup: start"; installs (opencode, nono, gams <ver>,
profile pulled); "setup: renv restored"; "setup: full run start" /
"setup: full run finished" / "setup: full run skipped
(MAGPIE_FULL_RUN=0)"; warnings (licence placeholder, low disk);
"setup: retry pass 2 after: <step>" when the fresh-process retry
starts; the check block; "sandbox check result"; "setup: run
finished". `setup: FAIL <step>` before every abort carries the WHOLE
help block (system string, check results or failed step, last 25 log
lines, hint) in the same post, capped at 3200 bytes for the whole
block (ntfy.sh rejects > 4096). The EXIT trap reports unexpected
deaths as "setup: CRASH exit=<code>" + last 10 log lines (same cap):
any code but 0/130, or 1 without a prior FAIL post; never in the
check-only child (the gate reports there). Teacher keeps the page
open, calls out code names of FAIL/silent students. Students that
never appear on the feed never started the script (PowerShell
instead of WSL, failed download) - absence is a signal too.

## 10. Next steps block

The manual `renv::restore()` line is GONE (6.9 does it). The block
shows `cd ~/magpie`, the completed full run folder (from the marker)
or the MAGPIE_FULL_RUN=0 skip note, and the own-scenario command
`Rscript start.R` ("choose 1, then 1"; macOS: `caffeinate -is
Rscript start.R`). The laptop advice stays (power, lid, overnight).

## 11. Verification status

Harness (tests/test-setup-magpie.sh, Linux x86_64 + AVX2 host else
exit 77 - the pinned GAMS/opencode linux builds are x86_64-only, fake
HOME, stub binaries only, real git only against a local origin; PATH is
a curated minimal bin dir so a host tex/pandoc/Rscript/gams can never
shadow the stubs; pinned block sedded to 9.9.9/fake shas; from an
interactive terminal the harness re-execs itself via `setsid -w` so the
handle box's /dev/tty Enter prompt can never block the suite): 460
assertions (461 with shellcheck on PATH) - syntax (bash/dash -n,
shellcheck -s sh where present); pin placeholder guard;
disk abort + warn tiers (incl. the raised 9 GB / 18 GB boundaries);
root guard; lock live/stale (a second window
exits quietly and leaves the FIRST run's keep-alive + `setup-dl-*`
untouched); system string before the OS is set; retry helper +
fresh-process pass 2; sudo loop
+ keep-alive (killed BEFORE the gate - asserted with a live keep-alive
in a dedicated sudo-prompt E2E, and `setup-dl-*.pkg` checksum mismatch
asserting no sudo ran before verification); handle create-once/reuse +
box;
feed POSTs recorded (start with file-hash header, check block, FAIL,
run finished); feed v2: sanitizer (home/host/user), combined FAIL
block with 3200 B cap (deep tail cut, screen + help file uncapped),
CRASH on unexpected exit (3, silent 1; none after a FAIL post, none
in the check-only child), retry-pass-2 announce; config
write incl. foreign `.bak`; HU key dedupe; cache dirs created + rc
lines deduped; licence placeholder/pasted/
mode-600/never-clobber/darwin-700; checks table (GAMS 54 + licensee
PASS, unlicensed FAIL, R/pandoc/tex/git lines, renv SKIP/PASS/FAIL,
full run SKIP-first/PASS/FAIL (each single missing artifact
FAILs)/SKIP-via-env);
check-only child isolation; pack pull pin + drift + profile build/
validate/keep-modified (+ cache write-list on both OSes); apt calls
carry the dpkg lock timeout (base + tools, update + install); TinyTeX
step (half `.TinyTeX` dir heals via rm -rf + reinstall, complete dir
skips + registers, no false heads-up); macOS pkg steps incl. checksum
mismatch
blocking sudo, gfortran off-PATH register (skip + install branches,
rc + run PATH); GAMS linux self-extractor; renv step (no renv.lock skip,
already-populated skip, broken library restored incl. activate.R
bootstrap, no bootstrap when renv present, persistent failure -> help
block, 3 attempts); clone guards (foreign dir,
foreign origin, interrupted heal, `setup-dl-*` leftovers tolerated,
`.setup-fullrun-ok` marker tolerated by the guard);
full run step (sandbox command shape, caches + PATH passed, marker +
artifacts written, keep-alive dead, verified marker skips, non-zero
exit -> help block (also with complete artifacts), swallowed run error
caught by missing artifacts, old folder not accepted as new, newest of
two complete folders wins into the marker, escape hatch, caffeinate
wrap on darwin);
E2E day-one green run (7 heads-ups, OK lines, rc dedupe, licence
written, clone checked out, no `.setup-finished`, `setup-dl-*` cleaned,
full run marker + artifacts + two `n` prompt answers on stdin,
profile write-list, cache rc lines)
+ second run all-skip (full run PASS line, start.R ran once)
+ E2E MAGPIE_FULL_RUN=0 (green, skip notes, no marker)
+ E2E deleted artifacts -> FAIL -> marker removal heals
+ E2E reproducible failure -> pass 2 -> help
block + FAIL feed line. Regression: tests/test-magpie-opencode.sh still
179/0 (incl. the new cleanup-ownership tests: owner exit stops the
keep-alive and removes the lock; a non-owner exit leaves both alone).

Live pending (course day / reference machines): real GAMS download +
extract, macOS pkg installs incl. Gatekeeper of `sudo installer`
targets, unattended CLT install, CONOPT in the overnight run log, HU
answer on HU network, the full day-one run incl. the real ~40 min
full run on Intel + Apple Silicon +
WSL, read/write-list completeness of `magpie-profile` (expect one denial
round per platform), stdin forwarding of `nono run` to the sandboxed
child (the full-run `n` answers rely on it).

## 12. Teacher to-do before the session

1. Paste `gamslice.txt` between the COURSE_GAMSLICE markers - in this
   ONE file only (the two old scripts are gone).
2. Upload `setup-magpie.sh` to Moodle (licence inside = course-only).
3. Run the live tests in 11; extend the profile read/write-list if a
   denial appears.
4. Bookmark the feed; archive it after the session.
