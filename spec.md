# MAgPIE course setup - spec

Status: implemented and unit-tested; reference-machine test pending.
Date: 2026-11-09.

## 1. Purpose

30 students, first terminal experience, 90-minute session. Each student
installs MAgPIE (github.com/magpiemodel/magpie) on macOS or Ubuntu 26 (WSL)
and starts one default model run. Nobody needs a finished run today.

Support model: one teacher + one TA for 30 laptops. The setup file is the
first responder, opencode (LLM) is the second, the ## help block feeds the
LLM, the ntfy feed gives the teacher a live overview. Students self-heal;
the teacher fixes only classes of failure at the wall.

## 2. Design decisions

- Two standalone bash files, one per OS. Students download ONE file from
  Moodle. No sidecar files, no USB sticks.
- GAMS (incl. course licence) and all tools install unattended via the
  script. macOS extras (Xcode CLT, Homebrew, R .pkg, gfortran .pkg) follow
  the "rerun me" pattern - the file prints what to do, then stops.
- The script embeds the course GAMS licence (gamslice.txt, not
  machine-bound, teacher pastes it into the TEACHER SECTION). The file
  stays Moodle-only: it contains the licence.
- opencode and nono are installed automatically when missing (binaries
  only; no further nono configuration is done).
- Progress reports go to a secret ntfy topic. Students get a random code
  name (Animal + 3 digits) instead of their real name. No error logs are
  uploaded - students fix errors themselves with LLM support. The feed is
  the only status channel; the old manual pad was retired.
- Success = check block all PASS + default run started. The final gate
  repeats the checks inside the nono sandbox with profile magpie-profile.

## 3. Files

- setup-ubuntu.sh, setup-macos.sh - student deliverables (standalone)
- SETUP.md - student handout (posted with the scripts on Moodle)
- README.md - teacher notes: edits before distribution, 90-min runbook,
  triage map, nono sandbox profile section
- spec.md - this file

## 4. Script structure (shared parts are duplicated into both files on purpose)

### TEACHER SECTION (top of file, the only intended edits)

- STATUS_URL: ntfy topic URL ("" disables all uploading)
- DISK_WARN_GB=15, DISK_ABORT_GB=6
- GAMS 54.6.1 URLs + sha256 checksums, double-verified (HEAD re-check
  2026-11-09: all three URLs live, sizes match). Version bump:
  recompute with `curl -fL <url> | sha256sum` (Mac: `| shasum -a 256`).
- magpie_licence_text(): heredoc between COURSE_GAMSLICE marker lines
  where the teacher pastes gamslice.txt. Placeholder still inside =
  warning on screen + feed note "gamslice not embedded".

### Code name

~/.magpie-course-handle stores Animal+3 digits (54 animals x 900 numbers,
about 1% collision chance among 30 students - accepted). First run prints
the "NOTE IT DOWN" box; every later run greets with it.

### magpie_report "<text>"

Posts "<handle> | <OS arch> | <text>" to STATUS_URL with curl, 5 s
timeout, `--data-binary @-` (the only form ntfy decodes correctly), never
fails the caller.

### magpie_check_disk

df-based free-GB check at run start. Below WARN: warning + feed line
(students clean the Windows C: drive on WSL, the Trash on Mac). Below
ABORT: hard stop, exit 1.

### Agents (opencode + nono)

magpie_install_agents, runs early: Ubuntu right after `apt-get update` +
a dedicated `apt-get install -y curl` (curl and dpkg exist, base tools come
later); macOS after the brew guard. Early placement means the AI toolchain
works even if a later heavy step fails.
- opencode: skipped if on PATH or ~/.opencode/bin/opencode exists; else
  official installer `curl -fsSL https://opencode.ai/v2/install | bash`.
- nono Ubuntu: skipped if on PATH; else latest release detected from the
  GitHub redirect (github.com/nolabs-ai/nono), .deb downloaded to
  ~/magpie-downloads, `sudo dpkg -i` with `apt-get install -f -y`
  fallback, deb removed after success.
- nono macOS: `brew install nono`.
- All failures report to the feed and continue ("rerun me").

magpie_rc_add_path (helper): the only place that touches the rc PATH. Appends
one `export PATH` line to ~/.bashrc (Ubuntu) / ~/.zshrc (macOS) if the dir is
not mentioned there, and always exports the dir into the running script. Every
rc PATH change therefore also applies to the current run - later steps in the
same run (checks, sandbox gate) see the tool without a new terminal. The rc
line stays: the export dies with the script, later terminals need the line.
Return code 0 = line appended, so callers keep their own wording.

magpie_fix_bin_path: if opencode or nono is not on PATH but exists in
~/.opencode/bin, ~/.local/bin, ~/.nono/bin or /usr/local/bin, register that
dir through magpie_rc_add_path. Not found anywhere: NOTE on screen + feed
line.

### magpie_opencode_config

Writes ~/.config/opencode/opencode.json: HU Berlin LLM3 provider
(baseURL https://llm3-compute.cms.hu-berlin.de/v1, env HU_API_KEY, model
hu/llm3, enable_thinking). Identical file = skipped; foreign existing
file = backed up to .bak. HU_API_KEY is not checked - see
magpie_register_hu_key.

### magpie_register_hu_key

Runs right after the opencode config. Appends one grep-guarded
`export HU_API_KEY="required-but-not-used"` line to ~/.bashrc (~/.zshrc on
macOS) and exports the same value for the current run, so the sandboxed
gate inherits it. opencode only needs the variable to exist - the real
credential is injected by nono. The in-session export overwrites any value
the script was started with; an existing HU_API_KEY line in the rc file is
never rewritten.

### Licence

magpie_licence_available: detects the un-pasted placeholder and warns on
screen + feed. Writes nothing. It has no dependencies, so it runs right
after the disk check - the "not embedded" warning then reaches the feed
before the long installs instead of at the end.

magpie_install_licence: writes gamslice.txt where GAMS looks for it, so no
env var is needed (GAMS data directories, see the GAMS standard-locations
docs). Ubuntu: the GAMS system directory
`~/gams/gams*_linux_x64_64_sfx/gamslice.txt`. macOS:
`~/Library/Application Support/GAMS/gamslice.txt`, the first user data
directory - the docs say not to put the file in the GAMS system directory on
macOS, and the pkg folder `/Library/Frameworks/GAMS.framework/Resources` is
root-owned (mode 600 impossible there). Perms 600; an existing file is never
overwritten (a rerun prints "already in place"). No GAMS folder yet (Ubuntu):
"rerun this file" + feed line. It runs after the GAMS install and before the
checks, so a single run goes green.

GAMSLOCK is gone everywhere. The variable appears in neither the GAMS 54
docs nor the GAMS 54.1 binary, and a GAMSLOCK pointing at a missing file did
not change what GAMS 54.1 used: it read `License : /opt/gams/gamslice.txt`
from the system directory and printed "The installed license is valid."

### GAMS

Pinned version + sha256, from the official CDN
d37drm4t2jghv5.cloudfront.net/distributions/<ver>/...:
- Ubuntu: linux_x64_64_sfx.exe, download with resume (-C -) and retries,
  checksum check (corrupt = delete + "rerun me"), extract into ~/gams.
  No gamsinst - the official MAgPIE Dockerfile also skips it; magpie
  names its solvers itself. Unverified link: CONOPT (overnight reference
  run must show "Executing CONOPT").
- macOS: pkg per architecture (macosx_arm64 / macosx), checksum, then
  `sudo installer -pkg <pkg> -target /`.
- magpie_register_gams: one PATH line appended to the shell rc
  (grep-guarded) through magpie_rc_add_path, which also exports it for this
  run. The licence needs no rc entry (see Licence).
- Ubuntu x86_64 only: ARM-WRL gets a clean feed-reported FAIL (by design;
  ARM-WRL is unlikely).
- Verified URLs (HEAD): linux x86_64 670 MB, mac arm64 450 MB,
  mac x86_64 585 MB.

### TinyTeX + tex PATH

- Installed via the tinytex R package when ~/.TinyTeX is missing (macOS
  only when Rscript exists).
- magpie_texbin(): the tex directory from `command -v tex`, else the first
  ~/.TinyTeX/bin/*/ holding an executable tex. (The old fallback globbed
  bin/*/bin - TinyTeX has no second bin level, so it matched nothing and
  the sandbox silently lost tex.)
- magpie_register_tex(): after the install, registers the texbin dir through
  magpie_rc_add_path - the tinytex installer only edits rc files, so without
  the in-run export every fresh run showed a false FAIL tex + help block.
- magpie_sandbox_check() reuses magpie_texbin() for its explicit PATH
  injection.

### magpie_sudo_keep

`sudo -n true || sudo -v`: silent keep-alive before the long-gap sudo steps
(Ubuntu: before the -dev libraries apt block; macOS: before `sudo
installer`), so the sudo timeout never causes a surprise "blind" password
prompt. The script deliberately does NOT run fully as root: that would
leave root-owned dotfiles (~/.bashrc, the licence in the GAMS folder,
opencode/nono configs, ~/.TinyTeX) that break every later normal-user run,
and it would pipe
curl installers into a root shell.

### Checks (magpie_run_checks)

- gams: found via PATH or ~/gams scan (Ubuntu) / framework path (macOS), run
  in a temp dir with no licence env var - GAMS must find the file itself. The
  banner has to say "The installed license is valid" (GAMS 54 wording; older
  releases said "Licensee"). The old `grep -qi licensee` never matched GAMS
  54, so `PASS gams` was unreachable.
- git >= 2.23 (integer compare, BSD-safe), Rscript >= 4.3, pandoc, tex.
- renv library: only when run inside a directory containing renv.lock;
  loads lucode2 + gms. Otherwise the line reads SKIP.
- Prints the result block ("===== your result - it went to the course
  feed ====="), sends it to the feed as "check result" (unsandboxed) or
  "sandbox check result", and on any FAIL prints the ## help block.

### Help block (screen + ~/magpie-help.txt, never uploaded)

Beginner prompt ("fix the FAIL lines, one command at a time") + distro
(PRETTY_NAME / sw_vers) + arch + code name + results + last 25 lines of
~/magpie-setup-log.txt. The whole run is tee'd to that log; the
--check-only child deliberately does not write it. Students copy the
block into opencode or any AI chat.

### nono profile + sandbox gate

- magpie_ensure_base_profile: uses the base profile `opencode` if
  `nono profile list` shows it, otherwise `nono pull nolabs-ai/opencode`.
  No Moodle fallback. nono missing = note + skip, plain checks remain the
  verdict; pull failure = feed FAIL + skip.
- magpie_build_nono_profile: writes
  ~/.config/nono/profiles/magpie-profile.json (meta.name "magpie-profile",
  extends ["opencode"]; filesystem.read = Ubuntu: ~/gams (holds the licence),
  ~/.TinyTeX; macOS: /Library/Frameworks/GAMS.framework, R.framework,
  /usr/local/gfortran, ~/.TinyTeX, ~/Library/Application Support/GAMS (holds
  the licence)). `nono profile validate` must pass
  before install. An existing file that differs from the template is kept
  untouched (student/LLM fixes via draft->promote survive reruns).
- Final gate, after the unsandboxed checks:
  `nono run --profile magpie-profile -- env MAGPIE_CHECK_ONLY=1
  PATH=<TinyTeX bin>:$PATH bash "$0" --check-only`
  PATH is passed explicitly because `bash script` does not
  source the rc files. No licence env var: GAMS reads the file from a
  read-listed folder.
- `--check-only` (consumed only by the wrapper): greet + checks, exit.
  No tee, no installs, no re-wrap - recursion-proof.
- Plain PASS + sandbox FAIL = profile gap. Diagnosis: nono why --self,
  nono profile diff, or the students' LLM draft->promote flow.

### Main flow

Ubuntu: check-only branch -> tee -> OS guard -> greet -> disk -> licence
placeholder check ->
sudo prompt -> apt update -> apt curl -> agents install -> fix PATH ->
opencode config -> HU key export -> apt base tools (no curl, installed
earlier) -> sudo keep -> apt -dev library list -> R version warning ->
TinyTeX -> tex PATH register -> GAMS install -> licence install -> register ->
checks -> nono
profile + sandbox gate -> next steps.

macOS: check-only branch -> tee -> guard -> greet -> disk -> licence
placeholder check -> CLT
guard (open installer, exit) -> brew guard (print one-liner, exit) ->
agents install -> fix PATH -> opencode config -> HU key export -> brew
tools -> R/gfortran guard (manual .pkg double-clicks, arm64 vs x86_64;
prints, exit 0 - "rerun me" like the other guards, no cascading FAILs or
pointless sandbox run in a broken state) -> GAMS install (sudo keep + sudo
installer) -> licence install (~/Library/Application Support/GAMS) -> register
(PATH fallback to ~/.zshrc) -> TinyTeX ->
tex PATH register -> checks -> nono profile + sandbox gate -> next steps.

## 5. Student flow (SETUP.md)

Mac: Moodle download -> `bash ~/Downloads/setup-macos.sh` -> follow the
printed side-installs and rerun the same command until it runs to the
end. Ubuntu: download in the Windows browser (Moodle login blocks curl),
`cp /mnt/c/Users/YOURNAME/Downloads/setup-ubuntu.sh ~/`, then
`bash ~/setup-ubuntu.sh`.
Then: clone magpie into the home folder (never /mnt/c, never iCloud
Desktop), `Rscript -e 'renv::restore()'` (type y), rerun the setup file
inside ~/magpie for the final check, `Rscript start.R` -> 1 -> 1
(macOS: `caffeinate -is` prefix). Overnight: power on, lid open.
Help order: rerun -> ## block to LLM -> 2 neighbors -> TA. Conda users
deactivate first (Mac note). Disk target: ~15 GB free.

## 6. Feed protocol

Topic: https://ntfy.sh/magpie-course-cb3363c15a75 (secret name;
messages live ~12 h, save with /json?poll=1&since=all). Content:
"setup: start", opencode/nono/gams install lines, warnings (licence
placeholder, low disk, missing binaries), FAIL <step> lines, check
blocks, "sandbox check result", "setup: run finished". Teacher: keep the
page open, call code names of FAIL/silent students; silent > 10 min =
walk over. No PII on the feed.

## 7. Verification status

Done (bash -n + live tests on a Linux dev machine): licence
placeholder/pasted/idempotent/never-clobber states; disk pass/warn/abort;
tee log incl. flush behaviour; help block payload + file; check-only
isolation (no installs, no log, correct exit code - this test caught two
real bugs: local self-reference, missing "$@"); profile JSON accepted by
real `nono profile validate` (meta block, not top-level name - the schema
has no name field); base-profile branches (present / pull / no-nono) via
stubs; profile build idempotent + keeps modified file; agents skip and
missing branches via curl/sudo/dpkg stubs; PATH fix dedupe + NOTE branch;
gams checks (stub PASS, real unlicensed FAIL); register dedupe (HU_API_KEY)
+ in-session HU key export; feed upload verified against ntfy
(multi-line only via --data-binary);
reordering pass (see Main flow) checked with bash -n + diffs, texbin
(system-tex / TinyTeX-glob / empty case) and register_tex (rc dedupe +
in-session export) unit-tested by sourcing the script - shellcheck is not
installed on the dev machine.

Licence move + PATH export (harness .tmp/test-path-export.sh, 40 assertions
by sourcing both scripts under a fake HOME, PATH without tex, STATUS_URL
empty so nothing reaches the feed): every rc PATH dir is also in the session
PATH; rc lines stay deduplicated over two calls; no GAMSLOCK in the rc; the
licence lands in the target folder, mode 600, never clobbered, nothing
written on the placeholder, "rerun" hint when the GAMS folder is missing; the
gams banner pattern matches the GAMS 54 wording and the legacy "Licensee"
wording but not an unlicensed banner. Real GAMS 54.1 probe (no env var, temp
cwd): reads the licence from the system directory and prints "The installed
license is valid"; a GAMSLOCK pointing at a missing file is ignored. macOS
profile JSON with the licence path (contains a space) parses.

Pending (reference machines): real GAMS download/extract and macOS
`sudo installer`; agents against real installers; end-to-end sandboxed
gate; read-list completeness (expect one denial round per platform);
the licence path GAMS picks on macOS (verify the banner "License" line);
CONOPT without gamsinst (overnight run log); HU_API_KEY + opencode
answer; Moodle upload + WSL /mnt/c copy; macOS bash 3.2 under a real
macOS (all constructs chosen 3.2-safe: no mapfile, no ${x,,}, arrays
guarded under set -u).

## 8. Teacher to-do before the session

1. Paste gamslice.txt between the markers in BOTH scripts.
2. Upload both scripts + SETUP.md to Moodle (licence inside = course-only,
   never public).
3. Reference install + overnight default run on each platform: confirm
   "Executing CONOPT" in the log and a green sandboxed gate; extend the
   profile read-list if a denial appears.
4. One machine: check opencode answers with hu/llm3 (the script sets the
   placeholder HU_API_KEY, nono injects the real credential).
5. Bookmark the feed; archive it after the session.
6. Minute 0 slides: paste basics, blind password, ~15 GB free disk,
   hotspot fallback, code name etiquette.
