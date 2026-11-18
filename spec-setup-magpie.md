# setup-magpie.sh - spec (unified day-one course setup)

Status: implemented in setup-magpie.sh (tests: tests/test-setup-magpie.sh,
858 assertions (857 when shellcheck is absent), all green on a Linux
x86_64 dev host). Date: 2026-11-18.

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
error model, the same work-dir layout under `~/setup-magpie`.
`magpie-opencode.sh`
stays the daily launcher; the two scripts never clash (see 2).

Support model as in the old course scripts, new transport: students post
their progress and every failure (step text + capped log tail) to a PIK
Nextcloud upload-only folder (see 9), where the teacher reads them under
each machine's animal code name. There is no AI help block any more: on
failure the screen names the step, the code name and the path of
`setup-log.txt`, and that is what the student sends the TA.

## 2. Design decisions

- One file, both OSes. Branch on `uname` (Darwin | Linux), like
  `magpie-opencode.sh`. Shebang `#!/usr/bin/env bash` from line 1, run
  via `bash` only, baseline bash 3.2 (macOS stock /bin/bash) - no `[[`,
  no arrays, no `local`, no `$RANDOM`, no process substitution.
- The upload feed and the animal code name are KEPT (unlike
  `magpie-opencode.sh`): the teacher reads the posts on course day.
  The handle is `Animal+3digits` in `~/setup-magpie/.magpie-course-handle`,
  picked
  from `/dev/urandom` (no `$RANDOM`). First creation is atomic
  (noclobber): two concurrent first runs converge on one name. It is an
  internal per-machine id (feed posts and the username replacement),
  logged by `magpie_greet` but never greeted with on screen: the student
  reads the code name in the `system:` check header and, on a failure,
  in the verdict line. There is no interactive prompt.
- All state lives in the work dir `~/setup-magpie` (`MAGPIE_SETUP_DIR`,
  derived from `$HOME`, so the harness's fake HOME scopes every path):
  `setup-log.txt`, `.setup.lock/`, `.keepalive.pid`, downloads, the
  full-run marker `.setup-fullrun-ok` and the handle file
  `.magpie-course-handle`. `~/magpie` is reserved for the clone plus
  the repo-native artifacts the repo itself produces (`renv/`,
  `output/`, ...); only the clone step ever creates it. The SAME file
  names are used by `magpie-opencode.sh`'s work dir, so both scripts
  share one layout.
- `magpie_sweep_legacy` runs at entry (after creating the work dir,
  before the first step) and migrates machines whose state still sits
  in the old locations: the old `~/magpie/setup-log.txt` MOVES in (an
  existing work-dir log gets it APPENDED - history survives), the
  markers `.setup-finished` and `.setup-fullrun-ok` MOVE unless a
  work-dir copy already exists (current state wins, the shadowed old
  file is dropped), and `~/.magpie-course-handle` MOVES to the work dir
  when no handle exists yet (students keep their code name). The
  leftover names of dead layouts are deleted (`setup-dl-*`,
  `opencode-dl.tgz`, `opencode-extract/`, `nono-dl.tar.gz`,
  `nono-extract/`, `setup-help.txt`, `setup-help-profile.json`,
  `.keepalive.pid`, `.setup.lock/` under `~/magpie`), and the old
  relocation folder `~/.magpie-course` is removed (its copy regenerates
  on demand). `.setup-finished` stays `magpie-opencode.sh`'s finish
  marker ONLY - this script never writes it (the sweep may move an
  existing one into the work dir), so running both scripts side by side
  stays consistent. Every removal is best-effort (`2>/dev/null ||
  true`) - a machine where one rm fails must still run - and the
  function always returns 0. The clone guard's allowlist keeps all
  these names anyway: it is the second line for leftovers the sweep
  could not remove, and a leftover or foreign-looking file must never
  block a clone.
- Extra downloads (GAMS, R, gfortran, pandoc) go under
  `~/setup-magpie` named `setup-dl-*` and are deleted on success AND in
  the EXIT trap - a crash never leaves foreign files behind. Leftover
  or partial magpie RUN folders (`output/default_*`) are NEVER cleaned
  or touched.
- No Homebrew anywhere (Homebrew 5 refuses Intel Macs). macOS R /
  gfortran / pandoc / GAMS are pinned `.pkg` downloads, sha256-checked,
  installed with `sudo installer -pkg ... -target /`, each
  skip-if-done. Xcode CLT installs unattended via `softwareupdate`.
- Sudo is asked only inside steps that actually run, through the
  `magpie-opencode.sh` warm loop + keep-alive. The keep-alive stops
  right after the licence step - no later step touches sudo - and
  again BEFORE the sandbox gate; `magpie_stop_keepalive` also runs
  `sudo -k`, so no warm sudo credential may exist while a sandboxed
  process runs.
- Errors are only reported when reproducible (the `magpie-opencode.sh`
  model): in-step retries, then one full second pass in a fresh
  process; only a failure repeating in pass 2 prints the failure verdict
  (step, code name, log path - no `##` help block any more) and exits 1.
  This REPLACES the old course scripts' "continue
  after FAIL and keep installing" behaviour.
- The run ends with: unsandboxed checks -> all PASS: sandbox gate
  (`nono run --profile magpie-profile -- ... bash <thisfile>
  --check-only`) -> full default run inside the same sandbox (see 6.10)
  -> the SETUP COMPLETE verdict (screen + log) -> feed "run finished" ->
  exit 0.
  Any FAIL (step-level, check, or gate): feed the FAIL line(s), print
  the failure verdict (step, code name, log path), exit 1.
- The full default run (about 40 min on the students' machines) is part
  of the exit-0 guarantee. Escape hatch: env `MAGPIE_FULL_RUN=0` skips
  it (screen + feed note, checks line SKIP, no marker - setup still
  exits 0). The run gets ONE attempt: no step retries, no second pass;
  any failure goes straight to the failure verdict, exit 1 - the next
  manual rerun redoes it (the marker stays unwritten until verified).
- Deterministic data folders: `MADRAT_MAINFOLDER=$HOME/.madrat`
  (madrat mainfolder, cache lives under it) and
  `RENV_PATHS_CACHE=$HOME/.cache/R/renv` are fixed (not
  env-overridable), exported into the run, written as grep-guarded rc
  lines (`magpie_register_caches`), and passed explicitly into every
  sandboxed child - the nono profile grants read+write in exactly
  these folders.
- rc lines stay clean and never duplicate: `magpie_rc_newline` closes a
  missing final newline before an append, so a new export cannot merge
  into the file's last line. Dedupe recognition is exact - the three
  fixed variables use anchored `^export NAME=` greps, PATH entries use
  `magpie_rc_has_path` (adjacency check: only a real PATH field counts,
  comments and longer paths do not).
- Disk guard has two tiers (from the old scripts, env-overridable,
  raised for the full run): below `MAGPIE_DISK_ABORT_GB=9` the run
  aborts with the failure verdict; below `MAGPIE_DISK_WARN_GB=18` a
  warning goes on
  screen and to the feed.
- `HU_API_KEY`: exported for the run AND written as one grep-guarded
  rc line - there is no launcher in this script, students may start
  opencode later from a fresh terminal (the real credential is
  injected by nono).
- magpie is cloned by this script (`git init` + remote + `ls-remote` +
  fetch + `checkout -B`, the non-empty-directory-safe pattern from
  `magpie-opencode.sh`), so students never clone anything by hand (and
  the run needs no to-do list at the end).

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
    Target folder: `/opt/gfortran` = `MAGPIE_GFORTRAN_DIR_NEW` (6.4).
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
feed), `magpie_licence_text()` - the single place the teacher pastes
`gamslice.txt` (placeholder still inside = early warning on screen +
feed, nothing is written) - and `MAGPIE_COURSE_LICENSEE`
(`Potsdam-Institut`): the substring the checks demand in the GAMS
banner whenever it is set - embedded or not (see 6.6 and 8; without an
embedded slice the banner must additionally carry no demo/expired
wording); empty = weak generic check only. Both fill-ins are
hash-neutral: the feed's version hash masks them (see 9), so a build
keeps exactly one hash across filled copies.

## 5. Script skeleton and order of operations

Same scoped-redirect entry as `magpie-opencode.sh`: the real terminal is
saved on fd 4, the whole main run goes to `~/setup-magpie/setup-log.txt`,
screen output only through `magpie_say` (the sandbox-gate child is
log-only, 6.7). Before the redirect the entry creates the work dir
(failure verdict: `cannot create ~/setup-magpie`) and runs
`magpie_sweep_legacy` (2) - the entry NEVER creates `~/magpie`, only
the clone step does. The `--check-only` child (env
`MAGPIE_CHECK_ONLY=1` or argument) is branched BEFORE the work dir
creation and the log
redirect - it writes no log, takes no lock, runs no installs, creates
and sweeps nothing.
`--script-hash` exits even earlier: it prints the build's feed hash
(9) and leaves - no log, handle, lock, feed or relocation.

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
install + PATH -> licence -> stop keep-alive + `sudo -k` -> nono pack
pull/pin -> `magpie-profile` build -> magpie clone -> renv library
restore (6.9) -> checks -> (green: sandbox gate, full default run
(6.10), the SETUP COMPLETE verdict, feed "run finished", exit 0). Every slow step that
RUNS gets one `[HH:MM:SS] - installing ...` heads-up; installs print
`OK:` lines. Screen lines stay student-readable: tool internals (rc
PATH edits, licence file paths, nono profile/pack mechanics, the 9P
relocation) and the `magpie_greet` handle line are log-only, and
heads-up/OK labels use what students
meet in the course (R, pandoc, GAMS, magpie, "R packages", "course
sandbox settings") - never apt/pkg/renv/clone jargon.
The keep-alive stops right after the licence step (no later step
touches sudo) and again before the gate; `sudo -k` drops the cached
timestamp, so no warm sudo exists while the gate child OR the full run
sandbox executes.

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

One step: base tools (`git wget zip unzip r-base pandoc
build-essential cmake gfortran`) plus the full -dev library list from
the old `setup-ubuntu.sh` (gdal, fontconfig, freetype, fribidi, gdal,
git2, glpk, harfbuzz, jpeg, netcdf, png, poppler-cpp, cairo, ssl,
tiff5, udunits2, xml2, uv1, pari-gp, qpdf) and `libcurl4-openssl-dev`
only - Ubuntu 26.04 marks the two `libcurl4-*-dev` flavours as
conflicting (feed Lynx729), and renv source builds need the openssl
one alone. `Acquire::Retries=3`, `magpie_sudo_warm` inside. A failed
bulk install logs one escalation: `dist-upgrade -y` (stale WSL images
carry runtime libs older than the -dev candidates), then the same
install runs again inside the attempt (`magpie_apt_tools_install`
helper). The body then verifies the result: `pandoc` on PATH AND
`magpie_have_r` (Rscript >= 4.3) - an apt `r-base` older than 4.3 must
not read as success here. Up front, `magpie_ubuntu_floor` rejects
Ubuntu < 24.04 (its `r-base` is older than 4.3): `magpie_fail` names
the fix (`wsl --install -d Ubuntu-24.04`) instead of letting the checks
fail much later; it reads `/etc/os-release`, env-overridable via
`MAGPIE_OS_RELEASE`. Skipped when R >= 4.3, pandoc AND the build
libraries are all present (`magpie_apt_have_devlibs`: `dpkg -s` on nine
representative packages, status `install ok installed` required). All
three apt calls (also the git/curl one in 6.1) carry
`-o DPkg::Lock::Timeout=120`: the old feed's biggest Linux failure
cluster (`FAIL apt install of libraries`) is the dpkg lock held by
WSL's unattended-upgrades - far past the step-retry waits. apt now
waits up to 2 min per attempt for the lock (option since apt 1.9.11,
i.e. Ubuntu 20.04+ = the WSL floor).

### 6.4 Course tools - macOS

Three pinned-pkg steps, each skip-if-done: gfortran (skip: the FC probe
below), R (skip: `Rscript` >= 4.3), pandoc (skip: `pandoc` on PATH).
gfortran detection ASKS R, it never guesses an install dir:
`magpie_r_fc()` runs `R CMD config FC` in one `Rscript` call, keeps the
first whitespace-separated token, and prints it only when it is
executable (absolute path: `file.access(p, 1)`; a bare name is resolved
with `Sys.which` first, same test). `magpie_have_gfortran()` is
"R's FC resolves" whenever `Rscript` exists - R's own FC is the only
test that matters, and a PATH-provided gfortran is covered because FC
then resolves through `Sys.which`. With no `Rscript` yet (this step runs
BEFORE `magpie_step_r`) it falls back to the plain probes: `gfortran` on
PATH, `$MAGPIE_GFORTRAN_DIR_NEW/bin/gfortran` (default `/opt/gfortran`)
or the legacy `$MAGPIE_GFORTRAN_DIR/bin/gfortran` (default
`/usr/local/gfortran`). Both are variables so the harness can fake the
pkg dirs - `MAGPIE_GFORTRAN_DIR_NEW` joins `MAGPIE_GFORTRAN_DIR` on the
harness-overridable constants. Rationale (2026-11, feed `Pangolin317`):
the step looped on every fresh Mac - `gfortran-14.2-universal.pkg`
installs into `/opt/gfortran`, the old probe checked PATH and
`/usr/local/gfortran`, so it reinstalled the same pkg through all three
attempts of both passes ("The upgrade was successful" every time, never
detected). Verified since: the 12.2- AND the 14.2-universal pkgs BOTH
target `/opt/gfortran` (their release notes say so, and enumerating the
12.2 pkg's payload shows all 1373 paths under `./opt/gfortran/`), while
`/usr/local/gfortran` is what the superseded 6.x-era pkgs used - so
there is ONE pinned pkg (14.2, no per-R-version selector) and the legacy
dir survives only as a probe dir and a profile read entry. The pkg
target is NOT on PATH by default: after skip OR install,
`magpie_register_gfortran` puts the FC's own bin dir (`dirname` of the
resolved FC) in the rc + this run's PATH, falling back to the bin dir
that actually holds the probed gfortran (`$MAGPIE_PKG_GDIR/bin` - this
run's pkg target, `$MAGPIE_GFORTRAN_DIR_NEW` - then the legacy tree), or
renv restore compiles and the sandboxed children never find gfortran.
Download `setup-dl-<name>.pkg` -> `magpie_sudo_warm` ->
sha re-check right before `sudo installer -pkg ... -target /` (root
never reads a file that changed after verification) -> remove the
download. Checksum mismatch blocks BEFORE any sudo call. GAMS macOS
uses the same helper. Each attempt logs the pkg and its FC target
(`magpie_log` only); when the installer reports success and the FC still
does not resolve, the body returns 1 after ONE diagnostic log line
combining `fc=$(magpie_r_fc)` with one-line `ls` listings of BOTH
`$MAGPIE_GFORTRAN_DIR_NEW/bin` and `$MAGPIE_GFORTRAN_DIR/bin` - the
feed's 25-line tail then shows the machine's real state instead of three
identical `installer:` stanzas. The magpie-profile read list names BOTH
gfortran folders via those two variables, each listed once it exists
(6.7).

### 6.5 TinyTeX + tex PATH

Skip only when a working tex exists: `magpie_texbin()` output
non-empty (`command -v tex`, else the first TinyTeX bin dir holding an
executable tex - it searches `$HOME/Library/TinyTeX/bin/*/` then
`$HOME/.TinyTeX/bin/*/` on EVERY OS: `tinytex::install_tinytex()`
installs under `~/Library/TinyTeX` on macOS, under `~/.TinyTeX` on
Linux). A bare TinyTeX DIRECTORY
is NOT enough - a run killed mid-install left exactly the old feed's
permanent `FAIL tex not found` state; with no usable tex anywhere the
heal loop `rm -rf`s BOTH roots (`$HOME/Library/TinyTeX` and
`$HOME/.TinyTeX`) and the install reruns.
`magpie_texbin()` / `magpie_register_tex()` from the old scripts: the
registered dir goes through `magpie_rc_add_path` (adjacency-checked rc
line + export into this run) so the checks and the gate see tex
without a new terminal.

`magpie_tinytex_body()` REFRESHES tinytex before installing anything:
one `Rscript` call runs `install.packages("tinytex", repos = CRAN)`
with no `lib=` - the refresh lands in the user/default library, which
is first in `.libPaths()` and shadows any ancient framework copy - and
a SECOND `Rscript` call gates on `packageVersion("tinytex") >= "0.46"`
(`quit(status = 1)` below; it also fires when the refresh failed and
tinytex is simply missing) before running `tinytex::install_tinytex()`.
Rationale (2026-11, feed `Pangolin317`): her machine carried a tinytex
so old it still fetched `yihui.org/tinytex/TinyTeX-1.tgz` - a 404 since
the prebuilt releases moved to GitHub; 0.46 is the version floor whose
`install_prebuilt` uses the GitHub-aware downloader. The gate needs its
own call because `Rscript` exits 0 even when `install.packages` fails.
The body's output is NEVER silenced (no `>/dev/null 2>&1` anywhere -
the swallowed `install.packages` diagnostics are exactly what hid the
failed update from the feed): everything flows into the run log, and a
gate failure returns non-zero so `magpie_retry 3` and the pass-2 model
drive the retries like for every other step body.

### 6.6 GAMS + licence

Pinned download per OS/arch (see 4). Linux: self-extractor run inside
`~/gams` with the sha256 RE-checked right before the exe runs; x86_64
only (ARM-WRL = clean feed-reported failure verdict, by design). No
gamsinst. macOS: `sudo installer -pkg`. GAMS PATH registered via
`magpie_rc_add_path`. `magpie_gams_sysdir()` locates the GAMS SYSTEM folder -
the binary's home and where GAMS reads `gamslice.txt`: Linux prefers
the pinned `~/gams/gams*_linux_x64_64_sfx` folder (exact version
first), else the folder of any `gams` found on PATH; macOS the pkg
framework folder `/Library/Frameworks/GAMS.framework/Resources`.
Licence: `gamslice.txt` goes into `magpie_licence_dir()` - the system
folder on Linux, `~/Library/Application Support/GAMS` on macOS (dir
chmod 700; the root-owned pkg folder cannot hold mode 600). File mode
600. An embedded slice is installed only when it differs from what is
already there: identical -> "already in place"; different (typically
the demo slice the GAMS installer ships - existence alone must never
skip the course licence) -> replaced, previous copy kept as
`gamslice.txt.bak` + feed line. With NO embedded slice the existing
file is never touched; a missing GAMS folder
yields the "rerun" note + feed line. `magpie_licence_embedded()`
decides SILENTLY whether the teacher pasted real text (a blank
heredoc counts as NOT embedded);
`magpie_licence_available()` warns + feeds ONCE per run (cached in
`MAGPIE_LIC_MISSING` - the early placeholder check and this step share
one warning). A missing licence dir is created; an EXISTING dir that
refuses writes gets a "licence dir not writable" warning + feed line,
no write attempt. Whenever
`MAGPIE_COURSE_LICENSEE` is set, the checks demand that licensee in
the GAMS banner - embedded or not (see 8). GAMS reads the file from
there - no license env
var anywhere.

### 6.7 magpie-profile + sandbox gate

`~/.config/nono/profiles/magpie-profile.json`, extends
`["nolabs-ai/opencode"]` (extends resolves the pack-qualified profile
name - the bare `"opencode"` fails validation on 0.81.0);
`meta.description` carries the `MAgPIE course` marker
plus the `MAGPIE_PROFILE_SCHEMA` version (bumped whenever the generated
content changes - the marker identifies the file as ours, see below;
`10` added the modern gfortran tree, `11` moved the `read_file`
script/handle entries into the `~/setup-magpie` work dir below).
Read list: Linux `$HOME/gams` + `$HOME/.TinyTeX`, plus one extra entry
when `magpie_gams_sysdir()` reports a GAMS folder OUTSIDE `$HOME/gams`
(any PATH install); macOS
`/Library/Frameworks/GAMS.framework`, `/Library/Frameworks/
R.framework`, BOTH gfortran trees - `$MAGPIE_GFORTRAN_DIR_NEW`
(`/opt/gfortran`, the target of the pinned pkg and where a modern R's FC
plus its `f951`/run-time libraries live) and the legacy
`MAGPIE_GFORTRAN_DIR` (`/usr/local/gfortran`, the 6.x-era tree) - ,
`$HOME/Library/TinyTeX`,
`$HOME/.TinyTeX`, the licence dir. An optional read folder is listed
only when it EXISTS on disk - validation rejects a policy path that is
missing (`~/.TinyTeX` stays absent when apt provides texlive, the macOS
licence dir when no licence is embedded, the pkg framework/gfortran
folders when a tool came from elsewhere or is a generation older than
the other tree). Only
`/Library/Frameworks/GAMS.framework` is literal: `magpie_install_gams`
on macOS succeeds only with that folder present. R must be VISIBLE in
the sandbox, not only executable: apt R keeps `Renviron` and the base
library under its home (`/usr/lib/R`), the course stack under a
site-library - nono's default groups cover neither, and the 2026-11
gate died with `cannot find system Renviron` -> `FAIL R`. So whenever
`Rscript` is on PATH, the read list also holds `R.home()` and every
`.libPaths()` entry (queried unsandboxed while building the profile,
skipped silently without R; existence-gated like all optional
folders; entries under an already-listed folder dedupe, e.g. the base
library under `R.home()`). The R home's `etc/` entries (`Renviron`,
`ldpaths`, `repositories`) are SYMLINKED files into `/etc/R` on
Debian/Ubuntu, and a grant does not follow links out of its tree - so
the profile also lists the physical folder behind
`$R_HOME/etc/Renviron`, resolved with R itself
(`dirname(normalizePath(...))`, unsandboxed at build time; without
`Renviron`'s `EDITOR` R dies inside the sandbox at `utils` `.onLoad`,
which is what produced the 2026-11 `FAIL R older than 4.3`). On
non-symlink layouts (macOS framework) it resolves inside the R home
and dedupes away. Source builds get the compiler trees: the `/usr/bin`
gcc/g++/gfortran drivers are covered by nono's system groups, but they
posix_spawn `cc1`/`cc1plus`/`f951` from `/usr/libexec/gcc`, link via
`collect2` from `/usr/lib/gcc`, and every compile reads `/usr/include`
- all outside the groups (verified by a denied `posix_spawn` inside a
plain pack-profile sandbox, which cost 73 of 282 start.R packages).
The read list therefore also holds `MAGPIE_TOOLCHAIN_DIRS`
(Linux: those three) / `MAGPIE_TOOLCHAIN_DIRS_DARWIN`
(`/Library/Developer/CommandLineTools`), existence-gated and
harness-overridable. `MAGPIE_DPKG_DIRS` (`/var/lib/dpkg`) joins on
Linux: `start.R`'s requirements check probes system packages with
`dpkg-query`, and an unreadable status DB reports every system
library as missing. The `tools::R_user_dir()` trio (Linux
`~/.cache/R`, `~/.local/share/R`, `~/.config/R`; macOS
`~/Library/{Caches,Application Support,Preferences}/org.R-project.R`,
helper `magpie_r_user_dirs`) is READ and WRITABLE: packages cache
there AT LOAD TIME (`gdtools`' font cache inside `ggiraph`'s lazy
load is the 2026-11 example). Like the madrat/renv caches these
folders are created by `magpie_register_caches` before the profile
step, so the write entries can stay literal; read entries follow the
usual existence gate. On both OSes the read list also
holds the two data folders,
and the write list holds `$MADRAT_MAINFOLDER` (`$HOME/.madrat`) +
`$RENV_PATHS_CACHE` (`$HOME/.cache/R/renv`) + the `magpie_r_user_dirs`
trio (literal - `magpie_register_caches` has created them by then).
The full run downloads
input data into the run folder (`gms::download_distribute`); the
madrat mainfolder is the pinned cache for any madrat read, the renv
cache fills on renv restores.
The folders are created by `magpie_register_caches` before any
sandboxed child runs (write rules need existing paths). `nono profile
validate` must pass before install; on failure nono's message goes to
the setup log, followed by the rejected candidate as ONE extra log line
(`tr '\n' ' '`) - a bare "failed validation" would leave whoever reads
the feed blind, and the candidate must not be 60 lines: the failure post
carries the last 25 log lines, and a multi-line dump would push the real
diagnostics out of that tail. Nothing is written to a side file.
An existing file: identical - kept;
different but carrying the `MAgPIE course` description marker - stale
output of an older script version: replaced, old copy kept as `.bak`;
different WITHOUT the marker (hand-made or edited): kept untouched
(delete it to regenerate). After the checks are green and the
keep-alive is stopped, the gate reruns the checks inside the sandbox:

```
nono run --profile magpie-profile --allow-cwd -- env MAGPIE_CHECK_ONLY=1 \
  PATH=<texbin>:$PATH MADRAT_MAINFOLDER=... RENV_PATHS_CACHE=... \
  bash <thisfile> --check-only
```

`--allow-cwd` silences nono's interactive "Share cwd read+write?" prompt
(the gate's cwd is `~/magpie`; without the flag students would have to
answer, and the full run's piped answers would hit that prompt instead
of start.R). The profile additionally lists, via `read_file`, the two
files the sandboxed child must read by absolute path while `$HOME`
itself is unreadable there: the script (`$MAGPIE_SELF` - the child
re-executes `<thisfile>`, and this is how the 2026-11 run died with
exit 126 `Permission denied` after saying yes), and the course handle
file `$MAGPIE_HANDLE_FILE` (without it the check block reports an
empty code name). Each entry only appears when the file exists;
`magpie_init_handle` reads it tolerantly (`cat 2>/dev/null || true`,
fresh handle on empty/unreadable) so a stale profile can never leak a
`cat:` error into the checks. Moving the script regenerates the
profile through the marker check.

**9P relocation.** Students run
`bash /mnt/c/Users/<name>/Downloads/setup-magpie.sh` from `$HOME`; WSL
mounts Windows drives via 9P (`stat -f -c %T` -> `v9fs`) and Landlock
cannot enforce there reliably: nono warns for every `/mnt/c` policy
path and reads may be denied at random. Early in `magpie_entry` (the
non-check-only branch) `magpie_native_self_copy` checks the
filesystem type of `$MAGPIE_SELF`: for `v9fs`/`9p` it copies the file
to `~/setup-magpie/self/setup-magpie.sh` and re-points `MAGPIE_SELF`
there, so every sandboxed step - the `read_file` entry, the gate
child, the pass-2 re-exec - uses a native path and no Windows
username ever enters the profile or the feed. The Downloads original
stays untouched and is re-copied on every fresh run (edit-and-rerun
works); a rerun whose script is already native, and any system where
`stat -f` fails or reports another type (macOS: `apfs`/`hfs`), skip
the copy silently. The teacher's copy of the script holds the feed
credentials and the licence, and 9P sources are world-readable under
the usual 022 umask: the folder is forced 700 and the copy 600 on
EVERY relocation (`cp -f` recreates the file, so a one-time chmod would
not survive reruns). A failing folder creation or copy (rare - the
target sits in `$HOME`) keeps the run non-fatal, leaves `MAGPIE_SELF`
on the Windows path and logs exactly one line, so the failure post's
log tail explains the nono warnings that follow. The relocation is
silent on screen (one log
line) - the student never sees a 9P warning.

The call runs in a subshell whose combined output is appended to
`"$HOME/setup-magpie/setup-log.txt"` (`>>` + `2>&1`, exit code checked
directly): neither the child's output nor anything nono itself prints
(its version, pack and capability dump through `Applying sandbox...`)
reaches the screen - the parent has already printed the check block, so
a tee would only duplicate it and show the child's greet line and
nono's banner for the student. On a green gate the parent prints one screen line
"OK: sandbox check passed"; a failing gate goes through the retry +
pass-2 model, whose failure verdict posts the results + log tail to the
feed.
The child: greet + checks only, feed label "sandbox check result",
exit code = checks result, no lock/sudo/log-file/installs -
recursion-proof. The work dir is deliberately OUTSIDE the profile, so
the child cannot read the full-run marker there: the child's checks
print no full-run line (the parent already verified the marker after
the gate; the child's marker check stays silent and cannot FAIL on it).

### 6.8 magpie clone

`magpie_clone_body` / `magpie_clone_ok` / `magpie_clone_magpie` from
`magpie-opencode.sh` 6.9, incl. foreign-dir / foreign-origin guards and
the own-file allowlist - now the SAME list in both scripts, since both
share `~/magpie` and neither may block the other's clone. The entry
sweep (2) has already moved or removed most legacy names before the
guard runs; the allowlist stays as the second line for leftovers the
sweep could not delete, so it still covers magpie-opencode's
`.setup-finished` marker (tolerated, never written here), the legacy
`~/magpie` positions of this script's `setup-dl-*` downloads,
`.setup-fullrun-ok` and `.keepalive.pid`, and
`setup-help-profile.json`: the rejected-profile dump the 2026-11
distributed copies left behind - written exactly by the runs that died
at the profile step, BEFORE the clone, so a machine healing from that
failure presents it to a clone with no `.git`).
`magpie_clone_body` itself starts with `mkdir -p "$repo"`: the entry
creates no `~/magpie`, the clone is the only step that may.
Origin acceptance (`magpie_clone_url_ok`, keys from `magpie_url_key`):
a stored origin is normalized - trailing slash(es), trailing `.git`,
scheme, `user@`, scp-style `host:path` colon -> `/` - and accepted when
the key equals the configured URL's, names `magpiemodel/magpie`, or
ends in the same repo basename (a student's fork; a log line notes
"origin is ... using the existing clone"). An accepted but different
origin is kept as-is. An empty origin (removed remote) is own state:
no note, no failure - a clone that still resolves HEAD is kept, a
broken one goes to the clone body, which adds the configured remote.
Any other origin: foreign-origin failure.

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
restore"`. Real restores feed "setup: renv restored"; screen wording is
student-facing ("installing R packages, about 5-15 min" / "OK: R
packages installed"). Fills `$RENV_PATHS_CACHE`, so the sandboxed
run-folder renv restores (6.10) only copy from the cache.

### 6.10 full default run (sandboxed)

Runs after the gate, before the verdict. `MAGPIE_FULL_RUN=0`:
screen + feed note, return 0, no marker. Skip when the marker
`~/setup-magpie/.setup-fullrun-ok` (contains the run folder path
relative to `~/magpie`, e.g. `output/default_...`; the step verifies
`~/magpie/<that relative path>`) points at a folder that still
holds all verification artifacts. Otherwise ONE sandboxed attempt
(macOS wrapped in `caffeinate -is`):

```
(cd ~/magpie && nono run --profile magpie-profile --allow-cwd -- \
  env MADRAT_MAINFOLDER=... RENV_PATHS_CACHE=... \
      PATH=<gamsdir>:<texbin>:$PATH \
  bash -c 'cd "$HOME/magpie" && \
           Rscript start.R runscripts=default.R submit=direct')
```

Feed "setup: full run start" before, heads-up "about 40 min, keep the
laptop plugged in and awake". The run's own output goes to the log only
(no tee, like the gate) - the R noise stays off the screen. The
command's stdin gets flow-matched answers: WITH a `renv.lock` two `n`
lines answer `start.R`'s "Update now?" and `fixDeps` prompts (auto-
updating would drift from the restored lockfile); WITHOUT one (every
first full run) the prompt is the requirements check "Try to fix
automatically? (Y/n)" and the answer is `y` - answering no there
skips the entire dependency stack (the 2026-11 course runs halted on
"no package called 'lucode2'"). An EOF stdin would crash
`gms::getLine` (empty `readLines` -> `logical(0)` in `&&`), so the
answers are always piped. ONE attempt - no retry, no pass 2.
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
folder under ~/magpie)"`, exit 1. Verified success writes the
marker, prints the OK line and feeds "setup: full run finished".
Partial/failed run folders stay where they are (decision: never
clean).

## 7. Error handling (from `magpie-opencode.sh`)

- Network: `curl -sS -fL --retry 4 --retry-delay 5 --retry-all-errors
  --connect-timeout 15 --max-time 900`, `-C -` resume, intact-temp skip,
  checksum mismatch = delete + retry.
- Step retry 3x (10 s / 30 s waits), then pass 2 in a fresh process
  (`MAGPIE_PASS=2 exec bash <self>`; lock self-re-adoption, warm sudo
  timestamp survives). Pass 2 failure = the failure verdict, exit 1.
  Never a third pass.
- `magpie_fail` additionally feeds `setup: FAIL <step>` + the detail
  block (capped at 3200 B) before exiting, so the teacher reads a log
  tail, not just the step name. The detail = `System: <sys> | <arch> |
  code name: <handle>` + (`FAILED STEP (twice, reproducible): <step>`
  for step failures, the results list for check failures) + last 25 log
  lines. On screen, instead: `SETUP FAILED (twice, reproducible):
  <step>`, the check results (check failures only), `  your code name:
  <handle> - tell the TA this`, `  everything else:
  ~/setup-magpie/setup-log.txt`. No AI prompt, no `##` frame, no
  `setup-help.txt` - the code name plus the log file are what
  the student hands the TA. Fix hints stay inside the step text itself
  (that is where the Ubuntu/WSL hint already lives). Without a feed
  (`STATUS_URL` empty or no curl - nothing can be uploaded) the last 25
  log lines go to the screen instead of the feed pointer line.
- sudo: blind retry loop, cap 6, keep-alive only after a real prompt:
  `sudo -n true` every 60 s, cap 720 ticks (12 h), self-exit once the
  owner process is gone - the loop watches `$$`, captured BEFORE the
  fork (bash keeps `$PPID` at the OUTER parent inside a subshell).
  `magpie_stop_keepalive` kills the loop, removes the pidfile and runs
  `sudo -k` - killing the refresher alone is not enough, sudo
  remembers the password for minutes.

## 8. Checks (`magpie_run_checks`, bash 3.2 rewrite of the old block)

Results accumulate in a newline-separated string (no arrays):
`gams` (found via PATH or the per-OS locations, run in a `mktemp -d`
scratch dir, removed afterwards - never in the folder the script
stands in, because GAMS writes there; no scratch dir = FAIL; with
`MAGPIE_COURSE_LICENSEE` set, a banner naming that licensee PASSes as
`gams (course licence found)` - embedded or NOT: a machine whose course
licence is already installed survives a rerun of the unfilled script;
without an embedded slice the banner must additionally carry no
`demo|expired` wording (a demo can never pose as the course licence;
with an embedded one the name outranks it); else a banner matching
`demo|expired` FAILs (demo licence); else, with the licence embedded
and the name missing, FAIL "not the course
licence"; else the weak match `license is valid|licensee` (GAMS 54 +
legacy wordings) PASSes as `gams (license found)`; else FAIL - licence file missing),
`git >= 2.23` (integer compare), `Rscript >= 4.3` (probed with
`Rscript --vanilla`: the pure version test must not depend on the
project `.Rprofile`/renv - the gate child runs checks from `~/magpie`
where a not-yet-bootstrapped renv would otherwise fail the probe),
`pandoc`, `tex`, the R library check (lucode2+gms via a
`cd ~/magpie` subshell - the load test is what `start.R` needs): with
`~/magpie/renv.lock` it always runs (`PASS renv R library` / FAIL
"renv R library incomplete ... renv::restore()"); WITHOUT a lockfile -
every course machine, because `start.R` snapshots into the RUN folder,
never into the repo root - it runs from the full-run marker onwards as
`R libraries (lucode2, gms load)`, and a failure says "in ~/magpie run:
Rscript start.R once". Nothing is printed before the marker exists:
there is no library to test yet, and a SKIP line announcing that is
noise on every first run. Parent only (`MAGPIE_CHECK_ONLY` unset): a
Landlock denial on this probe would block the gate with a message the
student cannot act on, and the sandboxed full run that follows tests
the library far better. The `full run` line: `MAGPIE_FULL_RUN=0` ->
SKIP (skipped via MAGPIE_FULL_RUN=0); marker present -> run folder +
artifacts verified: PASS, else FAIL "full run artifacts missing - rerun
this file" (delete the marker and rerun to have the step redo the run);
NO marker -> nothing at all: the step at the end of this setup runs it
and the verdict block reports the outcome, so "not yet" is not a check
result. The full run line is cheap and read-only (marker
+ file tests); inside the gate child the work dir is invisible (6.7: the
profile deliberately stays outside it), so the marker reads absent there
and the line stays silent - it can never fail the gate. The block
prints to screen under one `system: <OS> <arch> | code name: <handle>`
line (no copy-block frame - the paste-into-an-AI flow is gone), goes to
the feed as "check result" (or "sandbox
check result" in the child), and any FAIL line ends the run (failure
verdict + exit 1; in the child: exit non-zero for the gate). PASS lines
are plain results, no side notes: the old
`- ask TA to confirm CONOPT once` suffix is gone, because this block is
also the feed post and a green run must never read as an open action.

## 9. Upload protocol (feed folder `https://cloud.pik-potsdam.de/public.php/webdav`)

`STATUS_URL` is the WebDAV URL of a PIK Nextcloud folder shared
"upload only". The share credentials go directly after `https://`,
where curl reads them from the URL - full example, `SHARE-TOKEN` and
`SHARE-PASSWORD` being the teacher's paste step:

`https://SHARE-TOKEN:SHARE-PASSWORD@cloud.pik-potsdam.de/public.php/webdav`

The filled-in file is NEVER committed (public repository); the anchored
test on that line catches it, because credentials in the URL make the
line no longer match. Upload-only means holders of the credential can
write but cannot read or list: write-only by construction.
`STATUS_URL=""` disables uploading entirely; a refused or unreachable
upload is silent (`curl -s`, `|| true`), so the course endpoint can die
mid-run without costing a student their setup.

Every post: `<handle> | <OS> <arch> | v<hash> | <text>` (text may be
multi-line) is written to a `mktemp` file and sent with `curl -m 5 -T
<file>` - a PUT with a real `Content-Length`, one file per post named
`<handle>-<YYYYMMDD>-<HHMMSS>-<pid>-<n>.log`. The counter matters: PUT
overwrites on the target, so two posts in one second must not share a
name. Never fails the caller. `v<hash>` = first 12 sha256 hex of this
file with the two teacher fill-ins MASKED (`magpie_setup_version`):
the `STATUS_URL=` line becomes a constant and the `COURSE_GAMSLICE`
heredoc body is dropped, markers kept - so every filled copy of one
build shares one hash, which the teacher records per build via
`bash setup-magpie.sh --script-hash` (early-exit flag: prints the hash,
no log/handle/lock/feed/relocation), and an agent maps hash -> build
across all distributed copies. Computed at entry (awk + uname-based
shasum/sha256sum, "unknown" if the tools are missing). Unknown hash =
truncated or edited download: anything outside the fill-ins changes the
hash, and a licence truncated inside the heredoc loses its closing
marker - the mask then swallows the file tail, so truncation there is
detected too. Every body passes `magpie_sanitize`
(one PII choke point inside `magpie_report`): $HOME -> `~`, hostname
-> `HOST`, the hostname minus its `.local` suffix -> `HOST`, the
account's real name (`magpie_realname`, when at least 3 characters) ->
the code name, username -> the code name (`${MAGPIE_HANDLE:-unknown}`).
Replacement is literal and token-boundary only: a token counts between
non-token characters, so a short name never hits inside an unrelated
word. Order: home, host, host base, real name, user. Secrets
never reach the log by design: sudo reads the password from the tty
only, the licence text is written to its file only, HU_API_KEY is the
literal placeholder here. The upload URL (with its credentials) never
reaches the log either: `curl -s -o /dev/null`. Sanitizing third-party
output is best-effort; handles stay pseudonymous.

Milestones: "setup: start"; installs (opencode, nono, gams <ver>,
profile pulled); "setup: renv restored"; "setup: full run start" /
"setup: full run finished" / "setup: full run skipped
(MAGPIE_FULL_RUN=0)"; warnings (licence placeholder, low disk);
"setup: retry pass 2 after: <step>" when the fresh-process retry
starts; the check block; "sandbox check result"; "setup: run
finished". `setup: FAIL <step>` before every abort carries the detail
block (system string, check results or failed step, last 25 log
lines) in the same post, capped at 3200 bytes for the whole
block (kept from the old transport: no server limit forces it now, and
small posts stay readable in the folder). `magpie_feed_on` (URL set +
curl present) is what `magpie_fail` checks to decide whether that post
happened: with no feed available the last 25 log lines go to the screen
instead, so an offline student still has something to read.
The EXIT trap reports unexpected
deaths as "setup: CRASH exit=<code>" + last 10 log lines (same cap):
any code but 0/130, or 1 without a prior FAIL post; never in the
check-only child (the gate reports there). Teacher reads the folder in
the Nextcloud web UI (no live page: files arrive as runs progress, and
`watch` on the folder listing works too), uses code names to track
FAIL/silent students. Students that never appear in the folder never
started the script (PowerShell instead of WSL, failed download) -
absence is a signal too. Retirement: untick the share link (further
uploads are refused, the scripts ignore it), delete the folder to purge
the data - no server state is left anywhere.

## 10. Verdict block

The LAST output of a successful run - the old NEXT STEPS block (cd,
run folder, own-scenario command, laptop advice) is GONE: the course
page has all of it, and a run that worked should end in something a
student recognises at a glance rather than four lines of instructions.
Three `magpie_say` lines between `=` bars (=, never #: nothing else in
the output uses them, so the verdict is the only banner, and the old
`##` frame must stay absent):

```
============================================================
 SETUP COMPLETE - MAgPIE is installed, checked and working
   checks: no FAIL   sandbox: ok   default run: <marker content>
============================================================
```

`default run:` is the marker content, or `skipped (MAGPIE_FULL_RUN=0)`
when the escape hatch was used (`see above` as the last resort, it
cannot happen on the green path). Those legacy `setup-help.txt` /
`setup-help-profile.json` dumps are gone long before the verdict: the
entry sweep (2) deletes them, green or failing alike - nothing writes
them any more, and a stale FAIL block next to a machine that just
passed everything is pure confusion. The same verdict is then the log's
last line: `magpie_log "SETUP COMPLETE - all checks passed, full run
<rel>"`, so `tail -n 1 ~/setup-magpie/setup-log.txt` answers "did it
work?"
without reading the whole file. Both the fresh-run path and the
marker-verified short-circuit print it - a rerun of a finished install
must not end in silence. `magpie-opencode.sh` prints one
`OK: setup complete - starting opencode in ~/magpie` line before the
launch, on both its fast path and its install path.

## 11. Verification status

Harness (tests/test-setup-magpie.sh, Linux x86_64 + AVX2 host else
exit 77 - the pinned GAMS/opencode linux builds are x86_64-only, fake
HOME, stub binaries only, real git only against a local origin; PATH is
a curated minimal bin dir so a host tex/pandoc/Rscript/gams can never
shadow the stubs; pinned block sedded to 9.9.9/fake shas; scenario
trees cloned from one template via hardlinks; previous scratch moved
aside with a detached background rm): 858
assertions (857 without shellcheck) - syntax (bash -n, bash32
guard on script and harness - it flags bash4+ syntax AND the 2's hard
rules: double bracket, dollar-RANDOM, process substitution - shellcheck
-s bash where present; a per-idiom fixture self-test pins the guard
pattern ITSELF, so narrowing it goes red); pin
placeholder guard;
disk abort + warn tiers (incl. the raised 9 GB / 18 GB boundaries; the
`df` probe target pinned on the SOURCE text - the stub answers
path-blind, so only the pin catches a probe regressing to a folder the
entry no longer creates);
a low-disk E2E on a WRITABLE HOME aborts before the clone and proves
the entry creates only the work dir - `~/magpie` comes with the clone
step alone;
root guard; entry guard (an
unwritable HOME: the failure verdict is the only output on screen, and
neither the work dir nor `~/magpie` is created); legacy sweep (old log
MOVED in, APPENDED when a work-dir log exists, markers moved with the
work-dir copy winning, handle moved unless a new one exists -
`magpie_greet` keeps a migrated code name and a fresh run without one
lands the new name in the work dir, `~/.magpie-course` removed, every
junk name dropped, and a FULL old-layout machine - state in `~/magpie`,
handle at the old path, junk everywhere - migrates through a green E2E
run that keeps the code name and verifies the MOVED full-run marker
against the run artifacts still sitting in the clone (the marker path
is clone-relative - nothing under `output/` moves) instead of
rerunning); lock live/stale (a second window
exits quietly and leaves the FIRST run's keep-alive + `setup-dl-*`
untouched; the stale reclaim is asserted from OUTSIDE the exit code -
an early `exit 0` inside the lock function (dead pid believed alive)
must not skip the proof: silent screen and the reclaimed lock released
on the owner's exit); system string before the OS is set; retry helper +
fresh-process pass 2; sudo loop
+ keep-alive (killed BEFORE the gate - asserted with a live keep-alive
in a dedicated sudo-prompt E2E, and `setup-dl-*.pkg` checksum mismatch
asserting no sudo ran before verification; a second start while the
pidfile pid is alive never stacks a second loop - same pid kept, owner
exit stops the one loop); handle create-once/reuse
(no box, and `magpie_greet` lands in the log, not on screen; a present
but EMPTY or UNREADABLE handle file heals to a fresh name, never an
empty one and never a leaked `cat:` error);
download policy pinned on the
source text (`curl -sS -fL --retry 4 --retry-delay 5
--retry-all-errors`, `--connect-timeout 15 --max-time 900`,
`magpie_curl -C - -o` - a quiet flag drop would keep the behavioural
download tests green while course downloads lose retries and the stall
guard); feed target guard (anchored credential-free `STATUS_URL`); PUT
uploads recorded with credentials stripped - the stub strips (a password
holding "@" too), a fake filled-in link proves no token/password reaches
any artifact (start
with masked-hash header, check block, FAIL, run finished); upload names
unique (handle-date-time-pid-counter, two posts in one second);
version-hash fill-in invariance (`--script-hash`: one hash for the
plain, licence-pasted, blank-heredoc and nofeed copies plus the repo
file, differs from the raw file hash, an edit outside the fill-ins
changes the hash, the flag itself touches no state); feed
v2: sanitizer (home/host/host-base/real-name/user, token
boundaries, `unknown` fallback without a handle),
`-s -o /dev/null` proven (stub response/progress noise never reaches
the log), failing upload never fails the caller, mktemp failure
silent, failing uploads ignored, `STATUS_URL=""`
uploads nothing, combined FAIL
detail with 3200 B cap (deep tail cut; the screen gets only the verdict
+ log path, and with `STATUS_URL=""` the log tail goes to the screen
instead of the feed pointer - pinned both ways: with a live feed the
tail must stay off the screen),
CRASH on unexpected exit (3, silent 1; none after a FAIL post, none
in the check-only child), retry-pass-2 announce; config
write incl. foreign `.bak`; HU key dedupe; cache dirs created + rc
lines deduped; rc appends survive a missing final newline; licence placeholder/
blank-heredoc/pasted/mode-600/demo-slice-replacement
(with `.bak` + feed line)/darwin-700; checks table (licensee-name PASS, demo FAIL,
foreign-licence FAIL, weak-check fallback, unlicensed FAIL, a
licensee-naming demo FAILs WITHOUT embedding (only the embedded name
outranks demo wording), probe temp dir
cleaned, no-scratch-dir FAIL, R/pandoc/tex/git lines, R library check
(no line before the marker, PASS/FAIL with the marker, probe never runs
in the gate child),
full run no line before the marker/PASS/FAIL (each single missing artifact
FAILs)/SKIP-via-env);
verdict block (`SETUP COMPLETE` banner on screen + the same verdict as
the log's last line, on BOTH the fresh-run and the marker-verified
rerun path, `skipped (MAGPIE_FULL_RUN=0)` variant; no `##` and no
failure line anywhere on a green run; no `setup-help.txt` ever
written - the stale dumps older copies left behind are deleted by the
entry sweep, green path or not);
check-only child isolation (the child creates not even the work dir;
with a full-run marker present but the whole work dir unreadable - the
real sandbox view - the child stays green and prints no full-run line);
pack pull pin + drift + wrong-version-after-
pull (a registry handing back a stale pack despite the pinned ref fails
the step, never a silent pass) + profile build/
validate/keep-modified/stale-generated-regenerates-with-`.bak` (+ cache
write-list on both OSes, the R user dirs asserted as read entries
INSIDE the `read` block - the same path in `write` must never satisfy
them - and as write entries; PATH-gams extra read entry);
9P relocation (Windows-drive copies relocate `MAGPIE_SELF` to the
native copy and the original stays untouched, the copy lands 600 under
a 022 umask with its folder 700, native reruns do not recopy, a missing
`stat` is tolerated, a blocked copy stays non-fatal
and is logged); apt calls
carry the dpkg lock timeout (base + tools, update + install); ubuntu floor
blocks < 24.04 with the wsl hint; dev-lib guard (missing or half-configured
package reruns the install, too-old apt R blocks the step); TinyTeX
step (half TinyTeX dir heals via rm -rf + reinstall on BOTH roots incl.
macOS `Library/TinyTeX`, complete dir skips + registers, no false
heads-up; body refreshes tinytex FIRST - `install.packages` call before
the gate call, its chatter reaches the log (never silenced), a pre-0.46
gate version fails the body, drives the retries to the cap and the
pass-2 verdict, and installs no tex folder - the gate floor is pinned
on the SOURCE text (`packageVersion < 0.46`: the Rscript stub mirrors
the contract, it cannot execute the snippet, so a silently lowered
gate must go red here); macOS pkg steps incl. checksum
mismatch
blocking sudo, gfortran off-PATH register (skip + install branches,
rc + run PATH), the FC-probe loop regression (stubbed R: FC resolves =
skip + the FC bin dir registered, FC unresolved = retry + fail with
ONE diagnostic line listing BOTH bin dirs; the snippet's mechanisms -
first-token scan, `file.access` executability gate, bare-name
`Sys.which` - pinned on the SOURCE text for the same reason);
GAMS linux self-extractor; renv step (no renv.lock skip,
already-populated skip, broken library restored incl. activate.R
bootstrap, no bootstrap when renv present, persistent failure -> the
failure verdict, 3 attempts); clone guards (foreign dir,
foreign origin, ssh/`.git`/trailing-slash/fork origin accepted, removed
origin proceeds, interrupted heal, and every legacy `~/magpie` name
tolerated by the guard as a UNIT (`magpie_clone_magpie` run with all
of them present at once - own log, help dumps, markers, `setup-dl-*`,
dl tarballs, extract dirs, pid + lock - since the real entry flow
already swept them; this also pins the clone step as the only maker of
`~/magpie`), one E2E proving the entry sweep moves the markers out of
`~/magpie` (clone then sees a bare folder, the run FAILs only on the
migrated stale marker),
and the two scripts' guard lists compared VERBATIM (comments aside -
both specs pin one shared list));
gate (child output and nono's own banner in the
log exactly once and NOT on screen, parent prints the sandbox OK line,
child exit code wins, sudo cooled at that instant), full run
step (sandbox command shape, caches + PATH passed, marker +
artifacts written, keep-alive dead + sudo cooled, verified marker skips, non-zero
exit -> failure verdict (also with complete artifacts), swallowed run error
caught by missing artifacts, old folder not accepted as new, newest of
two complete folders wins into the marker, escape hatch, caffeinate
wrap on darwin);
E2E day-one green run (7 heads-ups, OK lines, rc dedupe, licence
written, clone checked out, no `.setup-finished`, `setup-dl-*` cleaned,
full run marker + artifacts,
profile write-list, cache rc lines, greet line in the log and off
screen, plain `PASS gams (course licence found)` with no to-do note;
the flow-matched prompt answers - `y` without `renv.lock`, two `n`
with - are proven in the adjacent unit scenarios, incl. caffeinate on
darwin)
+ second run all-skip (full run PASS line, verdict banner on screen
and as the log's last line, start.R ran once)
+ E2E MAGPIE_FULL_RUN=0 (green, skip notes, no marker)
+ E2E deleted artifacts -> FAIL -> marker removal heals
+ E2E reproducible failure -> pass 2 -> failure
verdict + FAIL feed line (step named, code name on screen, no
`setup-help.txt`). Regression: tests/test-magpie-opencode.sh still
233/0 (pins among them: 4 guard-pattern fixture
self-tests, the cross-file guard-list identity, the verdict quoting
the log's last line, the entry guard on an unwritable HOME (4) plus
the low-disk E2E on a writable HOME (2) and its df probe pin (1), the
download policy pinned on the source text (3), the non-stacking
keep-alive restart (2), the sweep conflict semantics of the launcher's
own copy (6), and the post-pull pack version check (3); 232 without
shellcheck; incl. the cleanup-ownership tests: owner exit stops the
keep-alive and removes the lock; a non-owner exit leaves both alone;
the rc-append newline guard: an append to an rc without final
newline starts its own line; the launcher clone guard tolerating the
whole legacy `~/magpie` set as a unit - `setup-help-profile.json`,
`setup-dl-*`, `.setup-fullrun-ok`, markers, tarballs, extract dirs -
and an entry-sweep E2E moving an old-layout machine's state into the
shared work dir, the migrated finish marker driving the launcher's
fast path).

Live pending (course day / reference machines): real GAMS download +
extract, macOS pkg installs incl. Gatekeeper of `sudo installer`
targets, unattended CLT install, CONOPT in the overnight run log, HU
answer on HU network, the full day-one run incl. the real ~40 min
full run on Intel + Apple Silicon +
WSL, read/write-list completeness of `magpie-profile` (expect one denial
round per platform), stdin forwarding of `nono run` to the sandboxed
child (the full-run prompt answers rely on it).

## 12. Teacher to-do before the session

1. Paste `gamslice.txt` between the COURSE_GAMSLICE markers - in this
   ONE file only (the two old scripts are gone).
2. Insert the share token and password right after `https://` in
   `STATUS_URL` (see 9) - NEVER commit or upload the filled-in file.
3. Run `bash setup-magpie.sh --script-hash` on the filled file and
   record the printed hash with the build: the fill-ins are masked out
   (see 9), so every distributed copy reports this one hash.
4. Upload `setup-magpie.sh` to Moodle (licence + credentials inside =
   course-only).
5. Run the live tests in 11; extend the profile read/write-list if a
   denial appears.
6. Read the feed folder in the Nextcloud web UI during the session;
   afterwards untick the share link and delete the folder (see 9).
