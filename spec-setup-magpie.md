# setup-magpie.sh - spec (unified day-one course setup)

Status: implemented in setup-magpie.sh (tests: tests/test-setup-magpie.sh,
616 assertions (617 when shellcheck is present), all green on a Linux
x86_64 dev host). Date: 2026-11-14.

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

Support model as in the old course scripts, new transport: students post
their progress and every help block to a PIK Nextcloud upload-only
folder (see 9), where the teacher reads them under each machine's animal
code name; the `##` help block feeds the students' LLM, students
self-heal.

## 2. Design decisions

- One file, both OSes. Branch on `uname` (Darwin | Linux), like
  `magpie-opencode.sh`. Shebang `#!/usr/bin/env bash` from line 1, run
  via `bash` only, baseline bash 3.2 (macOS stock /bin/bash) - no `[[`,
  no arrays, no `local`, no `$RANDOM`, no process substitution.
- The upload feed and the animal code name are KEPT (unlike
  `magpie-opencode.sh`): the teacher reads the posts on course day.
  The handle is `Animal+3digits` in `~/.magpie-course-handle`, picked
  from `/dev/urandom` (no `$RANDOM`). First creation is atomic
  (noclobber): two concurrent first runs converge on one name. It is an
  internal per-machine id (feed posts and the username replacement),
  reported in `magpie_greet`; there is no interactive prompt.
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
  `magpie-opencode.sh` warm loop + keep-alive. The keep-alive stops
  right after the licence step - no later step touches sudo - and
  again BEFORE the sandbox gate; `magpie_stop_keepalive` also runs
  `sudo -k`, so no warm sudo credential may exist while a sandboxed
  process runs.
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
- rc lines stay clean and never duplicate: `magpie_rc_newline` closes a
  missing final newline before an append, so a new export cannot merge
  into the file's last line. Dedupe recognition is exact - the three
  fixed variables use anchored `^export NAME=` greps, PATH entries use
  `magpie_rc_has_path` (adjacency check: only a real PATH field counts,
  comments and longer paths do not).
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
feed), `magpie_licence_text()` - the single place the teacher pastes
`gamslice.txt` (placeholder still inside = early warning on screen +
feed, nothing is written) - and `MAGPIE_COURSE_LICENSEE`
(`Potsdam-Institut`): the substring the checks demand in the GAMS
banner while the licence is embedded; empty = weak generic check only.

## 5. Script skeleton and order of operations

Same scoped-redirect entry as `magpie-opencode.sh`: the real terminal is
saved on fd 4, the whole main run goes to `~/magpie/setup-log.txt`,
screen output only through `magpie_say` and the
tee'd sandbox-gate child (6.7). The `--check-only` child (env
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
install + PATH -> licence -> stop keep-alive + `sudo -k` -> nono pack
pull/pin -> `magpie-profile` build -> magpie clone -> renv library
restore (6.9) -> checks -> (green: sandbox gate, full default run
(6.10), next steps, feed "run finished", exit 0). Every slow step that
RUNS gets one `[HH:MM:SS] - installing ...` heads-up; installs print
`OK:` lines.
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

### 6.6 GAMS + licence

Pinned download per OS/arch (see 4). Linux: self-extractor run inside
`~/gams` with the sha256 RE-checked right before the exe runs; x86_64
only (ARM-WRL = clean feed-reported help block, by design). No
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
content changes - the marker identifies the file as ours, see below).
Read list: Linux `$HOME/gams` + `$HOME/.TinyTeX`, plus one extra entry
when `magpie_gams_sysdir()` reports a GAMS folder OUTSIDE `$HOME/gams`
(any PATH install); macOS
`/Library/Frameworks/GAMS.framework`, `/Library/Frameworks/
R.framework`, `/usr/local/gfortran` (via `MAGPIE_GFORTRAN_DIR`, whose
default is that literal), `$HOME/Library/TinyTeX`,
`$HOME/.TinyTeX`, the licence dir. An optional read folder is listed
only when it EXISTS on disk - validation rejects a policy path that is
missing (`~/.TinyTeX` stays absent when apt provides texlive, the macOS
licence dir when no licence is embedded, the pkg framework/gfortran
folders when a tool came from elsewhere). Only
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
and dedupes away. On both OSes the read list also
holds the two data folders,
and the write list is exactly `$MADRAT_MAINFOLDER` (`$HOME/.madrat`) +
`$RENV_PATHS_CACHE` (`$HOME/.cache/R/renv`). The full run downloads
input data into the run folder (`gms::download_distribute`); the
madrat mainfolder is the pinned cache for any madrat read, the renv
cache fills on renv restores.
The folders are created by `magpie_register_caches` before any
sandboxed child runs (write rules need existing paths). `nono profile
validate` must pass before install; on failure nono's message goes to
the setup log and the rejected candidate stays at
`~/magpie/setup-help-profile.json` (a bare "failed validation" would
leave the help block blind). An existing file: identical - kept;
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
to `~/.magpie-course/self/setup-magpie.sh` and re-points `MAGPIE_SELF`
there, so every sandboxed step - the `read_file` entry, the gate
child, the pass-2 re-exec - uses a native path and no Windows
username ever enters the profile or the feed. The Downloads original
stays untouched and is re-copied on every fresh run (edit-and-rerun
works); a rerun whose script is already native, and any system where
`stat -f` fails or reports another type (macOS: `apfs`/`hfs`), skip
the copy silently. The student sees one informational line about the
Linux-side copy - never a 9P warning.

The call runs in a subshell whose combined output goes through
`tee -a "$HOME/magpie/setup-log.txt" >&4`: the parent's stdout is the
log, so the tee is what puts the child's check block on the screen -
and into the log, exactly once. The gate returns `PIPESTATUS[0]`: the
child's exit code decides, never tee's.
The child: greet + checks only, feed label "sandbox check result",
exit code = checks result, no lock/sudo/tee/installs -
recursion-proof. Gate failure goes through the retry + pass-2 model.

### 6.8 magpie clone

`magpie_clone_body` / `magpie_clone_ok` / `magpie_clone_magpie` from
`magpie-opencode.sh` 6.9, incl. foreign-dir / foreign-origin guards and
the own-file allowlist (magpie-opencode's full list, incl. its
`.setup-finished` marker - tolerated, never written here - extended
with `setup-dl-*` and `.setup-fullrun-ok`).
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
restore"`. Real restores feed "setup: renv restored"; progress
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
(cd ~/magpie && nono run --profile magpie-profile --allow-cwd -- \
  env MADRAT_MAINFOLDER=... RENV_PATHS_CACHE=... \
      PATH=<gamsdir>:<texbin>:$PATH \
  bash -c 'cd "$HOME/magpie" && \
           Rscript start.R runscripts=default.R submit=direct')
```

Feed "setup: full run start" before, heads-up "about 40 min, keep the
laptop plugged in and awake". The run's own output goes to the log only
(no tee, unlike the gate) - the R noise stays off the screen. The
command's stdin gets two `n` lines:
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
  timestamp survives). Pass 2 failure = the `##` help block, exit 1.
  Never a third pass.
- `magpie_fail` additionally feeds `setup: FAIL <step>` before exiting.
  The help block = beginner prompt lines + `System: <sys> | <arch> |
  code name: <handle>` + (`FAILED STEP (twice, reproducible): <step>`
  for step failures, the results list for check failures) + last 25 log
  lines. No fix hints: the student pastes the block into an AI chat and
  fixes it with LLM help. Saved to `~/magpie/setup-help.txt`, framed
  between `##` lines.
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
`MAGPIE_COURSE_LICENSEE` set, a banner naming that licensee PASSes
("course licence found") - embedded or NOT: a machine whose course
licence is already installed survives a rerun of the unfilled script;
without an embedded slice the banner must additionally carry no
`demo|expired` wording (a demo can never pose as the course licence;
with an embedded one the name outranks it); else a banner matching
`demo|expired` FAILs (demo licence); else, with the licence embedded
and the name missing, FAIL "not the course
licence"; else the weak match `license is valid|licensee` (GAMS 54 +
legacy wordings) PASSes; else FAIL - licence file missing),
`git >= 2.23` (integer compare), `Rscript >= 4.3` (probed with
`Rscript --vanilla`: the pure version test must not depend on the
project `.Rprofile`/renv - the gate child runs checks from `~/magpie`
where a not-yet-bootstrapped renv would otherwise fail the probe),
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
file, computed at entry (uname-based shasum/sha256sum, "unknown" if the
tools are missing): an agent maps hash -> build, an unknown hash =
truncated/edited download. Every body passes `magpie_sanitize`
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
finished". `setup: FAIL <step>` before every abort carries the WHOLE
help block (system string, check results or failed step, last 25 log
lines) in the same post, capped at 3200 bytes for the whole
block (kept from the old transport: no server limit forces it now, and
small posts stay readable in the folder). The EXIT trap reports unexpected
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
shadow the stubs; pinned block sedded to 9.9.9/fake shas; scenario
trees cloned from one template via hardlinks; previous scratch moved
aside with a detached background rm): 616
assertions (617 with shellcheck on PATH) - syntax (bash -n, bash32
guard on script and harness, shellcheck -s bash where present); pin
placeholder guard;
disk abort + warn tiers (incl. the raised 9 GB / 18 GB boundaries);
root guard; lock live/stale (a second window
exits quietly and leaves the FIRST run's keep-alive + `setup-dl-*`
untouched); system string before the OS is set; retry helper +
fresh-process pass 2; sudo loop
+ keep-alive (killed BEFORE the gate - asserted with a live keep-alive
in a dedicated sudo-prompt E2E, and `setup-dl-*.pkg` checksum mismatch
asserting no sudo ran before verification); handle create-once/reuse
(no box - the greet line only);
feed target guard (anchored credential-free `STATUS_URL`); PUT
uploads recorded with credentials stripped - the stub strips (a password
holding "@" too), a fake filled-in link proves no token/password reaches
any artifact (start
with file-hash header, check block, FAIL, run finished); upload names
unique (handle-date-time-pid-counter, two posts in one second); feed
v2: sanitizer (home/host/host-base/real-name/user, token
boundaries, `unknown` fallback without a handle),
`-s -o /dev/null` proven (stub response/progress noise never reaches
the log), failing upload never fails the caller, mktemp failure
silent, failing uploads ignored, `STATUS_URL=""`
uploads nothing, combined FAIL
block with 3200 B cap (deep tail cut, screen + help file uncapped),
CRASH on unexpected exit (3, silent 1; none after a FAIL post, none
in the check-only child), retry-pass-2 announce; config
write incl. foreign `.bak`; HU key dedupe; cache dirs created + rc
lines deduped; rc appends survive a missing final newline; licence placeholder/pasted/
mode-600/never-clobber/darwin-700; checks table (licensee-name PASS, demo FAIL,
foreign-licence FAIL, weak-check fallback, unlicensed FAIL, probe temp dir
cleaned, no-scratch-dir FAIL, R/pandoc/tex/git lines, renv SKIP/PASS/FAIL,
full run SKIP-first/PASS/FAIL (each single missing artifact
FAILs)/SKIP-via-env);
check-only child isolation; pack pull pin + drift + profile build/
validate/keep-modified/stale-generated-regenerates-with-`.bak` (+ cache
write-list on both OSes, PATH-gams extra read entry); apt calls
carry the dpkg lock timeout (base + tools, update + install); ubuntu floor
blocks < 24.04 with the wsl hint; dev-lib guard (missing or half-configured
package reruns the install, too-old apt R blocks the step); TinyTeX
step (half TinyTeX dir heals via rm -rf + reinstall on BOTH roots incl.
macOS `Library/TinyTeX`, complete dir skips + registers, no false heads-up); macOS pkg steps incl. checksum
mismatch
blocking sudo, gfortran off-PATH register (skip + install branches,
rc + run PATH); GAMS linux self-extractor; renv step (no renv.lock skip,
already-populated skip, broken library restored incl. activate.R
bootstrap, no bootstrap when renv present, persistent failure -> help
block, 3 attempts); clone guards (foreign dir,
foreign origin, ssh/`.git`/trailing-slash/fork origin accepted, removed
origin proceeds, interrupted heal, `setup-dl-*` leftovers tolerated,
`.setup-fullrun-ok` marker tolerated by the guard);
gate (child output on screen AND in the log
exactly once, child exit code wins, sudo cooled at that instant), full run
step (sandbox command shape, caches + PATH passed, marker +
artifacts written, keep-alive dead + sudo cooled, verified marker skips, non-zero
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
187/0 (incl. the cleanup-ownership tests: owner exit stops the
keep-alive and removes the lock; a non-owner exit leaves both alone;
and the rc-append newline guard: an append to an rc without final
newline starts its own line).

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
2. Insert the share token and password right after `https://` in
   `STATUS_URL` (see 9) - NEVER commit or upload the filled-in file.
3. Upload `setup-magpie.sh` to Moodle (licence + credentials inside =
   course-only).
4. Run the live tests in 11; extend the profile read/write-list if a
   denial appears.
5. Read the feed folder in the Nextcloud web UI during the session;
   afterwards untick the share link and delete the folder (see 9).
