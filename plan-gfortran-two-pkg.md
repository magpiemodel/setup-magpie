# Plan 1 — gfortran install loop on macOS: one pinned pkg, detection by asking R

Repo: `/home/pascal/setup-magpie`, branch `main` (base `ad5a52c` or later).
Read `AGENTS.md` first — its hard rules bind this change. This plan changes
`setup-magpie.sh`, `spec-setup-magpie.md`, `tests/test-setup-magpie.sh` and
one `AGENTS.md` gotcha line. Do NOT touch `magpie-opencode.sh` or the TinyTeX
step (that is `plan-tinytex-refresh.md`).

## Context (2026-11 course, from the student feed logs)

Student `Pangolin317` (macOS 15.8.1, R 4.4.0): `magpie_step_gfortran` looped —
`installer:` printed "The upgrade was successful" on all 3 attempts of both
passes, yet the step failed every time. Root cause, verified from primary
sources:

- `gfortran-14.2-universal.pkg` (what the script installs, `GFORTRAN_URL` @
  `setup-magpie.sh:37-39`) installs into **`/opt/gfortran`** — stated by the
  R-macos gcc-14-branch release notes and the R-admin manual Appendix C.3.2.
  It creates no `/usr/local/bin/gfortran` symlink.
- `magpie_have_gfortran()` (`setup-magpie.sh:1065`) probes only
  `command -v gfortran` and `$MAGPIE_GFORTRAN_DIR/bin/gfortran`, whose default
  (`setup-magpie.sh:108`) is **`/usr/local/gfortran`**. A successful 14.2
  install is therefore never detected, on every fresh macOS machine: the pkg
  lands in `/opt`, the probe looks at PATH and `/usr/local`, and the loop
  reinstalls the same pkg until the step fails.

## plan correction (verified)

The first revision of this plan (committed as `ad5a52c`) concluded from the
R-macos guidance that the Fortran target depends on the installed R — R
4.3/4.4 -> `gfortran-12.2-universal.pkg` at `/usr/local/gfortran`, R >= 4.5 ->
the 14.2 pkg at `/opt/gfortran` — and prescribed TWO pinned pkgs selected per
R version. That premise is FALSE; implementation stopped before pinning
anything. Re-checked evidence:

- Both gcc-12-branch and gcc-14-branch release notes on mac.r-project.org
  state the same install target for their universal pkgs: *"It installs into
  `/opt/gfortran`."*
- Full enumeration of `gfortran-12.2-universal.pkg`'s payload (xar → gzip'd
  cpio) shows **all 1373 paths under `./opt/gfortran/`, zero under
  `./usr/local/`**. Observed sha256 at
  `mac.r-project.org/tools/gfortran-12.2-universal.pkg`:
  `64a3185515d007aa1017644e860a26a5e0ff8c8446f164b96cbc94905e198535`,
  ~253.6 MB — recorded for reference only, NOT pinned anywhere.
- `/usr/local/gfortran` is the target of much OLDER (6.x-era) gfortran pkgs,
  which is why it still shows up in old R-admin text and on machines that
  installed gfortran years ago.

So a second pkg would buy nothing: 12.2 and 14.2 install to the SAME folder,
and the only thing that decides which compiler R uses is R's own `Makeconf`.
The per-R-version selector is dropped. **Revised design: keep the single
pinned 14.2 pkg, detect gfortran by asking R which Fortran compiler it uses,
and make the profile read both gfortran trees.** The `/usr/local/gfortran`
probe stays as a legacy fallback (a machine with a 6.x-era install already
has a usable gfortran and must not reinstall anything).

## Design decisions (agreed — implement as specified)

Do NOT guess paths from the OS or the R version: ask R which Fortran compiler
it uses, via `R CMD config FC`.

### 1. Constants (`setup-magpie.sh`, near lines 37-39 / 108 / 130)

- Keep `GFORTRAN_VERSION/URL/SHA256` = the 14.2 pkg (no legacy trio, no
  per-R-version selector); document that its target is
  `MAGPIE_GFORTRAN_DIR_NEW`.
- New: `MAGPIE_GFORTRAN_DIR_NEW="${MAGPIE_GFORTRAN_DIR_NEW:-/opt/gfortran}"`,
  the modern pkg target. `MAGPIE_GFORTRAN_DIR` (`/usr/local/gfortran`) stays
  as a **legacy fallback probe dir** for 6.x-era installs. Both are
  harness-overridable; add `MAGPIE_GFORTRAN_DIR_NEW` to the
  harness-overridable constants list (spec 6.4 + the `AGENTS.md` idiom line).
- **Bump `MAGPIE_PROFILE_SCHEMA` from `"9"` to `"10"`** (`setup-magpie.sh:130`)
  — the generated `magpie-profile.json` content changes (new read entry).
  AGENTS.md hard rule; the stale marker makes student machines regenerate.

### 2. New helper `magpie_r_fc()`

Prints R's Fortran compiler path, but only when it is executable; empty
otherwise. One `Rscript` call: take the first whitespace-separated token of
`R CMD config FC`; if it contains `/` test it with `file.access(p, 1) == 0`,
else resolve via `Sys.which()` and apply the same access test. `2>/dev/null`,
never fails the caller. Expected FC strings: R 4.4 prints e.g.
`/usr/local/gfortran/bin/gfortran -arch arm64`, R >= 4.5 prints
`/opt/gfortran/bin/gfortran ...`, an R with no Fortran prints something
`Sys.which` cannot resolve (or an empty string) -> empty output.

### 3. `magpie_have_gfortran()` (1065) — behavior change, document it in the spec

- If `Rscript` exists: present <=> `magpie_r_fc` prints something. R's own FC is
  the only test that matters (covers PATH-provided gfortran too, since then FC
  typically resolves via `Sys.which`).
- If `Rscript` does NOT exist (fresh machine — this step runs BEFORE
  `magpie_step_r`): fall back to the current probes: `command -v gfortran` or
  `-x "$MAGPIE_GFORTRAN_DIR_NEW/bin/gfortran"` or
  `-x "$MAGPIE_GFORTRAN_DIR/bin/gfortran"`.

### 4. Package selection + step rework (`magpie_step_gfortran` 1159, body 1175)

Unchanged pkg selection: the single 14.2 pin (`MAGPIE_PKG_URL`/`MAGPIE_PKG_SHA`
= `GFORTRAN_URL`/`GFORTRAN_SHA256`), plus `MAGPIE_PKG_GDIR=$MAGPIE_GFORTRAN_DIR_NEW`
for this run — the folder this script's pkg installs into. The skip-if-present
check and the `magpie_retry 3` model stay as they are. Log one line per attempt
naming the pkg and the FC target (log-only, per the stdout-verbosity rules).

`magpie_gfortran_body()`: after `magpie_install_pkg` succeeds, if
`magpie_have_gfortran` still fails, emit ONE diagnostic `magpie_log` line
combining `fc=$(magpie_r_fc)` and one-line `ls` listings of BOTH
`"$MAGPIE_GFORTRAN_DIR_NEW/bin"` and `"$MAGPIE_GFORTRAN_DIR/bin"` (piped
through `tr '\n' ' '`), then return 1 — so the feed's 25-line tail finally
shows real state instead of repeated identical `installer:` stanzas.
The `ls` parts must never fail the body.

### 5. `magpie_register_gfortran()` (1073)

Register in the rc (+ this run's PATH) the bin dir holding the FC when FC
resolved (its `dirname`, when not already on PATH); otherwise the bin dir that
actually holds the gfortran the fallback probes found — `$MAGPIE_PKG_GDIR/bin`
(the modern pkg target) first, then the legacy `$MAGPIE_GFORTRAN_DIR/bin`, and
`$MAGPIE_PKG_GDIR/bin` as the last resort. Registering a dir that holds no
gfortran would leave the compiles and the sandboxed children without a
compiler, which is exactly what the registration exists to prevent. Same
rc-append guarding as today.

### 6. Profile read list (`setup-magpie.sh:1606`)

Add `magpie_add_read_dir "$MAGPIE_GFORTRAN_DIR_NEW"` next to the existing
`MAGPIE_GFORTRAN_DIR` line (the helper's existence gate applies as usual —
`nono validate` rejects missing policy paths). Together with the schema bump
this makes the gate/full-run sandboxes able to read the tree the FC really
lives in (`f951` and the Fortran runtimes), on modern (`/opt`) as well as
legacy (`/usr/local`) machines.

## Spec sync (`spec-setup-magpie.md`)

- Section 6.4 pinned-pkg steps (~line 265 ff): the FC probe as the detection
  mechanism ("ask R, never guess the path"), the verified fact that BOTH the
  12.2- and 14.2-universal pkgs target `/opt/gfortran` (`/usr/local/gfortran`
  = 6.x-era only), the 2026-11 rationale (installer succeeds, 14.2 lands in
  `/opt`, the script checked `/usr/local` — a reproducible loop), and the
  diagnostic log line. Update the harness-overridable constants with
  `MAGPIE_GFORTRAN_DIR_NEW`.
- Profile section (~lines 338-347): the read list names BOTH gfortran dirs
  (existence-gated) and mentions the schema bump.
- After a green suite run, update the assertion counts from the ACTUAL output
  (lines 4 and ~762 — do not hardcode blindly).

## Tests (`tests/test-setup-magpie.sh`)

Harness idioms per AGENTS.md: `new_env` + `FN_BODY` + `run_fn [VAR=...]`,
stubs behind the minbin whitelist. The existing gfortran scenarios (~lines
1990-2030, `MAGPIE_GFORTRAN_DIR=...`, `STUB_GF_TARGET`) must keep passing —
adapt them to the new probe (extend the existing stub `Rscript`, which already
handles `install_tinytex` etc., with FC/version modes driven by state vars,
e.g. `STUB_FC_PATH` / `STUB_R_VER`). New scenarios (minimum):

1. Stub `Rscript` reports FC = an existing executable -> step skips with
   `gfortran: present`, rc gains that bin dir.
2. `Rscript` present but FC unresolved, pkg absent -> the 14.2 pkg URL is the
   one downloaded (assert via the stub download/install log).
3. `installer` stub succeeds but FC still unresolved -> body returns 1 and the
   diagnostic line (`fc=` + both dir listings) appears in the log.
4. No `Rscript` in minbin, an `/opt`-style dir (via `MAGPIE_GFORTRAN_DIR_NEW`
   override) has `bin/gfortran` -> step skips via the fallback probe.
5. No `Rscript`, both dirs absent -> 14.2 URL (fresh-machine branch).
6. Profile JSON: both gfortran dirs present when both exist; only the existing
   one otherwise; regenerated stale-profile marker carries schema `"10"`.

## Acceptance / verification

- `bash -n setup-magpie.sh`
- `bash tests/test-setup-magpie.sh` AND `bash tests/test-magpie-opencode.sh`
  fully green (offline; `(shellcheck not found - skipped)` is expected and is
  NOT a failure).
- `shellcheck -s bash setup-magpie.sh` clean (binary may live at
  `tests/shellcheck`).
- Profile sim trick per AGENTS.md (real `nono` is not runnable inside agent
  sandboxes):
  `HOME=<fake> MAGPIE_SOURCED=1 bash -c '. ./setup-magpie.sh; MAGPIE_OS=linux MAGPIE_GFORTRAN_DIR_NEW=<existing-dir> ... magpie_build_nono_profile'`
  + a stub `nono` on PATH that checks the JSON paths exist; confirm both
  gfortran dirs and the new schema marker are in the JSON.
- Commit style: short, lowercase, one-line (see `git log`).

## Out of scope

TinyTeX body (plan 2), `magpie-opencode.sh`, the R >= 4.3 floor, feed/telemetry
wording, `magpie_install_pkg` internals, pinning the 12.2 pkg (dropped: same
install target as 14.2, see the correction above).

## Coordination note

`plan-tinytex-refresh.md` is code-disjoint from this plan but edits the same
two files (`tests/test-setup-magpie.sh`, `spec-setup-magpie.md`) in different
sections. Implementing both? Go sequentially (either order) or use separate
worktrees and merge; the second implementer must recount the spec's assertion
numbers after the merged suite run.
