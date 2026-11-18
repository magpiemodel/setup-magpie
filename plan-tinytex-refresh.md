# Plan 2 — TinyTeX 404 on machines with a stale tinytex: refresh it in the default library

Repo: `/home/pascal/setup-magpie`, branch `main` (base `d0c70fe` or later).
Read `AGENTS.md` first — its hard rules bind this change. This plan changes
`setup-magpie.sh` (one function body), `spec-setup-magpie.md` and
`tests/test-setup-magpie.sh`. Do NOT touch `magpie-opencode.sh`, the gfortran
step, the nono profile or `MAGPIE_PROFILE_SCHEMA` (the profile content is
untouched here — no schema bump). The gfortran work is `plan-gfortran-two-pkg.md`.

## Context (2026-11 course, from the student feed logs)

Student `Pangolin317` (macOS 15.8.1, R 4.4.0, German locale): `TinyTeX install`
failed on all attempts of two runs with

```
versuche URL 'https://yihui.org/tinytex/TinyTeX-1.tgz'
curl: (56) The requested URL returned error: 404
Fehler in download_file(...) : No download method works (auto/wininet/wget/curl/lynx)
Ruft auf: <Anonymous> ... install_prebuilt -> download_installer -> download_file
```

The prebuilt-TinyTeX asset on `yihui.org` is dead — releases moved to GitHub
(`rstudio/tinytex-releases`), which tinytex >= ~0.46 (2023) knows; tinytex
versions before that still request the dead URL. Her machine had such a stale
tinytex installed. `magpie_tinytex_body()` (`setup-magpie.sh:1216`) does
`install.packages("tinytex", repos = CRAN) >/dev/null 2>&1` before
`tinytex::install_tinytex()` — but the silencing means any update failure
(e.g. unwritable library, blocked download) vanished without a trace, and
nothing verified that the tinytex about to run `install_tinytex()` is modern.
The body is unchanged since the Monday build the students ran.

**Agreed design (keep it simple):** refresh tinytex in its default library —
no scratch libraries, no `R_LIBS` games — plus stop silencing and refuse to
run a pre-0.46 downloader.

## Design

Replace the body with exactly this behaviour (adapt formatting to the script's
style; keep the comment block, it is the rationale the spec points at):

```sh
magpie_tinytex_body() {
  # 2026-11 course machines carried a tinytex so old it still fetched
  # yihui.org/tinytex/TinyTeX-1.tgz - a 404 since the prebuilt releases
  # moved to GitHub. Refresh tinytex in its default library FIRST (the
  # user library is first in .libPaths() and shadows any ancient
  # framework copy), and never silence the installer: the swallowed
  # output is what hid the failed update from the feed. The version gate
  # has to live in its own Rscript call - Rscript exits 0 even when
  # install.packages fails - and a pre-0.46 tinytex would run the dead
  # downloader and abort the body anyway.
  Rscript -e 'install.packages("tinytex", repos = "https://cloud.r-project.org")'
  Rscript -e 'if (packageVersion("tinytex") < "0.46") quit(status = 1)
    tinytex::install_tinytex()'
}
```

Behaviour notes (assert these in tests):

- `install.packages` (no `lib=` argument) refreshes tinytex in the user/default
  library; its stdout/stderr now flows into the run's log/tee like every other
  step body — no `>/dev/null 2>&1` anywhere.
- The gate exits non-zero on a stale tinytex (or on any error, e.g. tinytex
  missing because the install failed) -> the existing `magpie_retry 3` +
  pass-2 model drives retries; on repeated failure `magpie_step_failed
  "TinyTeX install"` behaves as before, but now the log tail actually contains
  the `install.packages` diagnostics.
- `magpie_step_tinytex` (skip-if-tex, incomplete-folder heal loop,
  `magpie_register_tex`) stays untouched.
- 0.46 is the version floor below which `install_prebuilt` used the dead URL;
  document that rationale once in the spec.

## Spec sync (`spec-setup-magpie.md`)

- Section 6.5 (TinyTeX + tex PATH, ~line 280 ff): state that the body first
  refreshes tinytex in the default library and gates on `packageVersion >=
  0.46`, with the 2026-11 stale-tinytex/404 rationale and the "output is never
  silenced" rule.
- After a green suite run, update the assertion counts from the ACTUAL output
  (lines 4 and ~750 currently say 766/767 — do not hardcode blindly; if the
  gfortran plan already landed, use the merged suite's numbers).

## Tests (`tests/test-setup-magpie.sh`)

The stub `Rscript` (handles `*install_tinytex*` around line 259, logging to
`$STATE/rscript.log`) must be extended to cover both new call shapes:
`install.packages` invocations and the version-gate call. Drive the gate with a
state var (e.g. `STUB_TINYTEX_VERSION`, exit code derived from comparing
against `0.46`; default: pass, so the existing scenarios at ~lines 1568-1607
keep passing unchanged).

New scenarios (minimum):

1. Gate version >= 0.46 -> body returns 0; rscript.log shows the
   `install.packages` call BEFORE the gate/install_tinytex call.
2. Gate version < 0.46 (e.g. `0.36`) -> `magpie_tinytex_body` returns 1
   (drives retries); with the retry wrapper, the step failure text is
   unchanged.
3. Stub `install.packages` output (a marker string) reaches the log — asserts
   nothing is silenced any more.
4. Existing darwin/linux step scenarios (skip-if-tex, incomplete-folder heal)
   still green.

## Acceptance / verification

- `bash -n setup-magpie.sh`
- `bash tests/test-setup-magpie.sh` AND `bash tests/test-magpie-opencode.sh`
  fully green (offline; `(shellcheck not found - skipped)` is expected and is
  NOT a failure).
- `shellcheck -s bash setup-magpie.sh` clean (binary may live at
  `tests/shellcheck`).
- No profile-related change: the generated `magpie-profile.json` must be
  byte-identical to before this change (spot-check with the sim trick from
  AGENTS.md if in doubt; `MAGPIE_PROFILE_SCHEMA` stays at its current value).
- Commit style: short, lowercase, one-line (see `git log`), e.g.
  `refresh tinytex before installing`.

## Out of scope

gfortran step (plan 1), nono profile + schema, `magpie_step_tinytex` skip/heal
logic, `magpie-opencode.sh`, direct-URL prebuilt installers, scratch libraries.

## Coordination note

`plan-gfortran-two-pkg.md` is code-disjoint from this plan but edits the same
two files (`tests/test-setup-magpie.sh`, `spec-setup-magpie.md`) in different
sections. Implementing both? Go sequentially (either order) or use separate
worktrees and merge; the second implementer must recount the spec's assertion
numbers after the merged suite run.
