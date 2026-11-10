# magpie-lab - teacher notes

Student files: `setup-ubuntu.sh`, `setup-macos.sh` (both fully standalone)
plus SETUP.md as the handout. All three go into the course folder on Moodle
(students know how to get there). No USB sticks, no pad - the ntfy feed is
the only status channel.

## Before distributing - edit the TEACHER SECTION of BOTH scripts

1. Paste `gamslice.txt` between the `COURSE_GAMSLICE` marker lines.
   Unpasted = students get a warning and the feed shows it immediately.
2. Pin the GAMS version: URLs + sha256 are in the header. After a version
   bump, recompute with (per URL):
   `curl -fL <url> | sha256sum` (on a Mac: `curl -fL <url> | shasum -a 256`).
   Checksums now pinned: GAMS 54.6.1, computed 2026-11-09.
3. Upload both scripts + SETUP.md to Moodle. Moodle login blocks plain
   `curl`, which is why SETUP.md tells WSL students to download in the
   Windows browser and copy via `/mnt/c`.
4. The scripts embed the course licence - Moodle-only. Never post them in
   public repos, chats, or an open room Wi-Fi landing page.

## Pre-session checklist

1. Reference install on your machine: run the file end to end (it pulls
   ~700 MB of GAMS), then clone+renv+`start.R`. You are the reference.
2. Confirm CONOPT works once: the overnight default run log must show
   "Executing CONOPT" - without it the run dies late, so test BEFORE today.
3. Bookmark the live feed (also in the scripts' STATUS_URL):
   `https://ntfy.sh/magpie-course-cb3363c15a75`
   Students appear as code names (Dingo598, Zebra347, ...), stage by stage -
   this is the complete record, no pad needed. Dev-machine test messages
   expire within 12 h, ignore them.
4. After the session (messages live only ~12 h), save the record:
   `curl -s "https://ntfy.sh/magpie-course-cb3363c15a75/json?poll=1&since=all" > setup-$(date +%F).json`
5. Wi-Fi: ~3 GB per laptop (GAMS + apt/brew + renv). Phone-hotspot fallback
   is in the handout. No USB exists anymore - weak Wi-Fi = slow session.

## 90-minute runbook

| Min | Students | Teacher / TA |
|---|---|---|
| 0-8 | Terminal basics, start the file | Project the expected screen of every stage |
| 8-50 | Setup file (+ Mac: R/gfortran/brew side-installs, rerun pattern) | Explain while things install; TA roams |
| 50-60 | Rerun file until all PASS | Watch feed, call out code names of FAIL/silent students; fix CLASSES of failure at the wall |
| 60-80 | clone magpie + `renv::restore()` + final check run inside `~/magpie` | TA 1:1 only; queue: 2 neighbors -> opencode -> TA -> teacher |
| 80-90 | `Rscript start.R` default run started (overnight); stragglers pair up | Declare done; run results = next session |

## Triage map (from the feed / check block)

- `WARNING gamslice not embedded` -> YOUR problem: paste the licence and
  re-host the file; tell seated students to rerun.
- `FAIL gams download corrupt` -> rerun downloads the file again; persistent
  = server/Wi-Fi, pair the student.
- `FAIL gams found but its licence file is missing` -> the licence is not in
  the GAMS folder (Ubuntu `~/gams/gams*/`, Mac
  `~/Library/Application Support/GAMS/`); rerun writes it.
- `WARNING/FAIL low disk` -> student cleans the Windows side (WSL) or the
  Trash (Mac); thresholds are the DISK_* constants in the teacher section.
- `FAIL tex/gams ... not found` right after success -> rerun this file; the
  PATH lines it writes are also applied to the run itself.
- renv restore network timeout -> rerun `Rscript -e 'renv::restore()'`,
  it resumes.
- WSL: magpie cloned under `/mnt/c` -> reclone in `~`.
- Code name silent on the feed > 10 min while others pass it -> call the
  name, walk over.

## nono sandbox profile

Scripts create `~/.config/nono/profiles/magpie-profile.json` (extends the
registry profile `opencode`, `nono pull nolabs-ai/opencode` if missing,
never overwrites a student-modified file) and end with a sandboxed
self-check. TA manual equivalent on a student machine (PATH is passed
explicitly because `bash script` does not source the shell rc files; the
licence needs no variable - GAMS reads it from the GAMS folder, which is on
the profile read-list):

Replace `<texbin>` with the directory holding `tex` (usually
`~/.TinyTeX/bin/<platform>`):

```
nono run --profile magpie-profile -- env MAGPIE_CHECK_ONLY=1 \
  PATH=<texbin>:$PATH \
  bash ~/setup-ubuntu.sh --check-only
```

(Mac: `~/Downloads/setup-macos.sh`.) Feed titles: `check result` = plain
run, `sandbox check result` = inside nono. Plain PASS + sandbox FAIL =
profile gap: `nono why --self --path <denied-path> --op read` on that
machine, or let the students' LLM use nono's draft -> promote flow.
After the course, students work daily inside it:
`nono run --profile magpie-profile -- opencode`.

## Session boundaries

- Success = check block all green + default run started. Nobody needs a
  finished run today.
- The setup file contains the course licence - keep the download link
  course-only, do not paste the file into public repos/chats.
