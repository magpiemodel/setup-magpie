# Plan 1 — gfortran install loop on macOS: two pinned pkgs selected per R version

Repo: `/home/pascal/setup-magpie`, branch `main` (base `d0c70fe` or later).
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
- `magpie_have_gfortran()` (`setup-magpie.sh:1047`) probes only
  `command -v gfortran` and `$MAGPIE_GFORTRAN_DIR/bin/gfortran`, whose default
  (`setup-magpie.sh:108`) is **`/usr/local/gfortran`** — the target of the OLD
  gfortran-12.2-universal.pkg. A successful 14.2 install is therefore never
  detected, on every fresh macOS machine.
- The Fortran target depends on the installed R: R-macos guidance maps
  **R 4.3/4.4 -> gfortran-12.2-universal.pkg at `/usr/local/gfortran`** (their
  `Makeconf` hard-codes an absolute FC path under `/usr/local/gfortran`) and
  **R >= 4.5 -> gfortran-14.2-universal.pkg at `/opt/gfortran`**. Installing
  only 14.2 on an R 4.4 machine satisfies the step but breaks Fortran package
  compiles during the sandboxed `start.R`/renv phase.

## Design decisions (agreed — implement as specified)

Two-pkg design. Do NOT guess paths from the OS: ask R which Fortran compiler
it uses, via `R CMD config FC`.

### 1. Constants (`setup-magpie.sh`, near lines 37-39 / 108 / 130)

- Keep `GFORTRAN_VERSION/URL/SHA256` = the 14.2 pkg; document that its target
  is `MAGPIE_GFORTRAN_DIR_NEW`.
- New: `MAGPIE_GFORTRAN_DIR_NEW="${MAGPIE_GFORTRAN_DIR_NEW:-/opt/gfortran}"`.
- New legacy trio: `GFORTRAN_LEGACY_VERSION="12.2"`,
  `GFORTRAN_LEGACY_URL="https://mac.r-project.org/tools/gfortran-12.2-universal.pkg"`,
  `GFORTRAN_LEGACY_SHA256="<pin during implementation, see below>"`. The
  existing `MAGPIE_GFORTRAN_DIR` stays the legacy target and stays
  harness-overridable; add `MAGPIE_GFORTRAN_DIR_NEW` to the harness-overridable
  constants list in the spec.
- **Pin the legacy sha256 during implementation:** download the ~242 MB pkg
  once, `sha256sum` it, and sanity-check its install target by inspecting the
  xar TOC payload encoding and scanning the payload for a `usr/local/gfortran`
  path prefix (e.g. `gunzip -c ... | strings` if the payload is gzip'd cpio;
  also verify the gcc-12-branch release notes on GitHub state that target).
  If reality contradicts this plan, STOP and flag instead of pinning a wrong
  sha or installing the wrong layout.
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
`/opt/gfortran/bin/gfortran ...`.

### 3. `magpie_have_gfortran()` (1047) — behavior change, document it in the spec

- If `Rscript` exists: present <=> `magpie_r_fc` prints something. R's own FC is
  the only test that matters (covers PATH-provided gfortran too, since then FC
  typically resolves via `Sys.which`).
- If `Rscript` does NOT exist (fresh machine — this step runs BEFORE
  `magpie_step_r`): fall back to the current probes: `command -v gfortran` or
  `-x "$MAGPIE_GFORTRAN_DIR_NEW/bin/gfortran"` or
  `-x "$MAGPIE_GFORTRAN_DIR/bin/gfortran"`.

### 4. Package selection + step rework (`magpie_step_gfortran` 1141, body 1157)

Replace the fixed `MAGPIE_PKG_URL`/`MAGPIE_PKG_SHA` assignment at 1147 with a
selector: R major > 4, or major == 4 and minor (first component of
`R.version$minor`) >= 5 -> 14.2 pkg + `MAGPIE_PKG_GDIR=$MAGPIE_GFORTRAN_DIR_NEW`;
R 4.3/4.4 -> legacy pkg + `MAGPIE_PKG_GDIR=$MAGPIE_GFORTRAN_DIR`; no `Rscript`
-> 14.2 (the R step installs 4.6 right after, whose FC is under `/opt`). bash
3.2 only: plain `[ ... -ge ... ]` integer tests with sane fallbacks on
unparsable versions, no `[[`, no arrays. Log one line per attempt naming the
chosen pkg and the FC target (log-only, per the stdout-verbosity rules).

`magpie_gfortran_body()`: after `magpie_install_pkg` succeeds, if
`magpie_have_gfortran` still fails, emit ONE diagnostic `magpie_log` line
combining `fc=$(magpie_r_fc)` and one-line `ls` listings of both `<dir>/bin`
(piped through `tr '\n' ' '`), then return 1 — so the feed's 25-line tail
finally shows real state instead of repeated identical `installer:` stanzas.
The `ls` parts must never fail the body.

### 5. `magpie_register_gfortran()` (1055)

Register in the rc (+ this run's PATH) the bin dir holding the FC target when
FC resolved (its `dirname`, when not already on PATH), else
`$MAGPIE_PKG_GDIR/bin` — same rc-append guarding as today.

### 6. Profile read list (`setup-magpie.sh:1588`)

Add `magpie_add_read_dir "$MAGPIE_GFORTRAN_DIR_NEW"` next to the existing
`MAGPIE_GFORTRAN_DIR` line (the helper's existence gate applies as usual —
`nono validate` rejects missing policy paths). Together with the schema bump
this makes the gate/full-run sandboxes on R >= 4.5 machines able to read
`/opt/gfortran` (f951 and the Fortran runtimes live there).

## Spec sync (`spec-setup-magpie.md`)

- Section 6.4 pinned-pkg steps (~line 265 ff): the pkg-per-R-version rule, the
  FC probe as the detection mechanism ("ask R, never guess the path"),
  `/opt/gfortran` vs `/usr/local/gfortran`, and the 2026-11 rationale
  (installer succeeds, 14.2 lands in `/opt`, the script checked `/usr/local` —
  a reproducible loop). Update the harness-overridable constants list with
  `MAGPIE_GFORTRAN_DIR_NEW`.
- Profile section (~lines 338-347): the read list names BOTH gfortran dirs
  (existence-gated) and mentions the schema bump.
- After a green suite run, update the assertion counts from the ACTUAL output
  (lines 4 and ~750 currently say 766/767 — do not hardcode blindly).

## Tests (`tests/test-setup-magpie.sh`)

Harness idioms per AGENTS.md: `new_env` + `FN_BODY` + `run_fn [VAR=...]`,
stubs behind the minbin whitelist. The existing gfortran scenarios (~lines
2000-2020, `MAGPIE_GFORTRAN_DIR=...`, `STUB_GF_TARGET`) must keep passing —
adapt them to the new probe (extend the existing stub `Rscript`, which already
handles `install_tinytex` etc., with FC/version modes driven by state vars,
e.g. `STUB_FC_PATH` / `STUB_R_VER`). New scenarios (minimum):

1. Stub `Rscript` reports R 4.6 + FC = an existing executable -> step skips
   with `gfortran: present`, rc gains that bin dir.
2. R 4.4.0, FC = missing legacy path, gfortran absent -> the legacy pkg URL is
   the one downloaded (assert via the stub download/install log).
3. R 4.6 (and a 4.5.x case) -> the 14.2 pkg URL.
4. No `Rscript` in minbin, both dirs absent -> 14.2 URL (fresh-machine branch).
5. `installer` stub succeeds but FC still unresolved -> body returns 1 and the
   diagnostic line (`fc=` + both dir listings) appears in the log.
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
- Commit style: short, lowercase, one-line (see `git log`), e.g.
  `gfortran pkg per r version`.

## Out of scope

TinyTeX body (plan 2), `magpie-opencode.sh`, the R >= 4.3 floor, feed/telemetry
wording, `magpie_install_pkg` internals.

## Coordination note

`plan-tinytex-refresh.md` is code-disjoint from this plan but edits the same
two files (`tests/test-setup-magpie.sh`, `spec-setup-magpie.md`) in different
sections. Implementing both? Go sequentially (either order) or use separate
worktrees and merge; the second implementer must recount the spec's assertion
numbers after the merged suite run.
