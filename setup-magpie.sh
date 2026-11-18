#!/usr/bin/env bash
# Unified MAgPIE course setup for macOS (arm64 + x86_64) and WSL Ubuntu.
# One file, run with: bash setup-magpie.sh. Safe to rerun.
# Installs: git/curl (or Xcode CLT), opencode, nono, HU config, course tools
# (apt libs | pinned pkgs), TinyTeX, GAMS + licence, nono profile, magpie
# clone, renv restore. Then checks (unsandboxed + sandbox gate), one full
# default run inside the sandbox, and a final SETUP COMPLETE verdict.
# Bash - baseline macOS stock /bin/bash 3.2, no bash4+ constructs.

# ============================================================
# Re-pin per asset: curl -fsSL <url> | sha256sum (macOS: shasum -a 256)
# ============================================================

OPENCODE_VERSION="2.2.7"
OPENCODE_SHA256_DARWIN_ARM64="8d4f90c5b23faa724ba1c877d8358072bbb6565c33b8d8b5dca7c7644c4de0bf"
OPENCODE_SHA256_DARWIN_X64="a2f1bd02c36e180d43999a70126212511ef67686345d600724dd93ea74de7601"
OPENCODE_SHA256_LINUX_ARM64="7e74ceb64fe5704ff2fdef3dee45866efcb580d71f182a6cae29606cad1f8b52"
OPENCODE_SHA256_LINUX_X64="d65935464f93f07913633f977cb99723af64eeff6ae7a822722ce89bedabdd45"

NONO_VERSION="0.81.0"
NONO_PACK_VERSION="0.4.2"
NONO_SHA256_AARCH64_APPLE_DARWIN="728b1deefbf6390c9b74fc982efbded1e1c4b37b99dcdefa2e07266dfef4d9e9"
NONO_SHA256_X86_64_APPLE_DARWIN="f795aa88faaf75975ffc600eb870e7c9f2b52ba2035df5087ec972a0252afd40"
NONO_SHA256_AARCH64_UNKNOWN_LINUX_GNU="a4d87ddb0917ef96224bcc41a2587318d7d0e92441e7ff454696e5980c9f7924"
NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU="7ecc33ff9c349bdfa84b4496e7a7555f67bcc33f1e125c7df9efb653c6c4e569"

GAMS_VERSION="54.6.1"
GAMS_URL_LINUX_X64="https://d37drm4t2jghv5.cloudfront.net/distributions/54.6.1/linux/linux_x64_64_sfx.exe"
GAMS_SHA256_LINUX_X64="ac198c6262ec781b351336f4fa7fe7afe3316c5db5c0593ea2d4e7579fd34eb1"
GAMS_URL_DARWIN_ARM64="https://d37drm4t2jghv5.cloudfront.net/distributions/54.6.1/macosx_arm64/GAMS54.6.1.pkg"
GAMS_SHA256_DARWIN_ARM64="0cb71b9682952afac7a203bdad310c1090765435f4d92960ae680c029ed1223b"
GAMS_URL_DARWIN_X64="https://d37drm4t2jghv5.cloudfront.net/distributions/54.6.1/macosx/GAMS54.6.1.pkg"
GAMS_SHA256_DARWIN_X64="f02a339236ad969abe6e161eda0ee39422360d33249ab9d15fa667ce191e8276"

# macOS-only pinned installers (no Homebrew). Re-pin: pick the current
# release at the URL, then curl -fsSL <url> | shasum -a 256.
# The gfortran pkg installs into MAGPIE_GFORTRAN_DIR_NEW (/opt/gfortran):
# both the 12.2- and the 14.2-universal pkgs target that folder (R-macos
# release notes; confirmed by enumerating the 12.2 pkg payload). Only the
# long-superseded 6.x-era pkgs used /usr/local/gfortran.
GFORTRAN_VERSION="14.2"
GFORTRAN_URL="https://mac.r-project.org/tools/gfortran-14.2-universal.pkg"
GFORTRAN_SHA256="ec462d465f093eeee0623d2b5d327bd1038313b985034b766462957e36d7aadd"

R_VERSION="4.6.2"
R_URL_DARWIN_ARM64="https://cran.r-project.org/bin/macosx/sonoma-arm64/base/R-4.6.2-arm64.pkg"
R_SHA256_DARWIN_ARM64="a678b4db1fcd71b1b1cc58edcfa4a8d36ee012a02659dde9eab9366e93571157"
R_URL_DARWIN_X64="https://cran.r-project.org/bin/macosx/big-sur-x86_64/base/R-4.6.2-x86_64.pkg"
R_SHA256_DARWIN_X64="aa9b1dba09cc69710571ad93efba26a9bcb5a0098543dadc4bb8e419a423195e"

PANDOC_VERSION="3.14"
PANDOC_URL_DARWIN_ARM64="https://github.com/jgm/pandoc/releases/download/3.14/pandoc-3.14-arm64-macOS.pkg"
PANDOC_SHA256_DARWIN_ARM64="33f1049a362f782b2f2ee81d99d110d0283047312650ce1ab7f5c9116ec9ca51"
PANDOC_URL_DARWIN_X64="https://github.com/jgm/pandoc/releases/download/3.14/pandoc-3.14-x86_64-macOS.pkg"
PANDOC_SHA256_DARWIN_X64="145a39969291a8af79fe81037be3eb6e56511f0056b4dfd562571312f0b9b7c7"

# ============================================================
# END PINNED BLOCK
# ============================================================

# ============================================================
# TEACHER SECTION - edit only here before distributing
# ============================================================

# Live status feed: a PIK Nextcloud folder, shared "upload only" and
# reached over WebDAV. Every post lands there as one small text file.
# Before distributing, insert the share credentials right after
# "https://" - curl reads them from the URL, so students do nothing.
# Full example, replace the two placeholders, keep the rest as it is:
# https://SHARE-TOKEN:SHARE-PASSWORD@cloud.pik-potsdam.de/public.php/webdav
# NEVER COMMIT the filled-in file - this repository is public. The
# committed value below holds no credentials. Set to "" to disable all
# uploading.
STATUS_URL="https://cloud.pik-potsdam.de/public.php/webdav"

# Paste the course gamslice.txt between the two COURSE_GAMSLICE lines.
magpie_licence_text() {
  cat <<'COURSE_GAMSLICE'
__PASTE_CONTENTS_OF_gamslice.txt_HERE__
COURSE_GAMSLICE
}

# Substring that must show up in the GAMS banner for the course
# licence to be believed. Whenever this is set, the checks demand it:
# with an embedded licence it outranks demo wording, without one the
# banner needs it (plus no demo/expired wording) to PASS as course -
# so a demo or foreign licence can never look like a PASS.
MAGPIE_COURSE_LICENSEE="Potsdam-Institut"

# ============================================================
# END TEACHER SECTION
# ============================================================

set -u

# Timing knobs (seconds) + disk tiers (GB, full run included).
# Env-overridable.
MAGPIE_DISK_WARN_GB="${MAGPIE_DISK_WARN_GB:-18}"
MAGPIE_DISK_ABORT_GB="${MAGPIE_DISK_ABORT_GB:-9}"
MAGPIE_RETRY_SECS="${MAGPIE_RETRY_SECS:-10}"
MAGPIE_RETRY_SECS2="${MAGPIE_RETRY_SECS2:-30}"
MAGPIE_PASS_SECS="${MAGPIE_PASS_SECS:-30}"
MAGPIE_KEEPALIVE_SECS="${MAGPIE_KEEPALIVE_SECS:-60}"
MAGPIE_SUDO_RETRY_SECS="${MAGPIE_SUDO_RETRY_SECS:-2}"

# Clone source. Variable only so the offline test harness can point
# it at a local repository.
MAGPIE_MAGPIE_URL="${MAGPIE_MAGPIE_URL:-https://github.com/magpiemodel/magpie.git}"

# gfortran pkg target (macOS): the folder the 12.2- AND 14.2-universal
# pkgs install into, and where a modern R's FC lives. Variables only so
# the offline test harness can fake the pkg install dirs.
MAGPIE_GFORTRAN_DIR_NEW="${MAGPIE_GFORTRAN_DIR_NEW:-/opt/gfortran}"

# Legacy gfortran tree: target of the long-superseded 6.x-era pkgs.
# Probe dir and profile read entry only - this script never installs
# there; a machine that already has it has a usable gfortran.
MAGPIE_GFORTRAN_DIR="${MAGPIE_GFORTRAN_DIR:-/usr/local/gfortran}"

# Compiler trees the sandboxed renv builds need readable+executable:
# the gcc drivers in /usr/bin are covered by nono's system groups,
# but they posix_spawn cc1/cc1plus/f951 from /usr/libexec/gcc and
# collect2 from /usr/lib/gcc, and the preprocessor reads /usr/include
# - all outside those groups (verified by an actual denied compile).
# Space-separated, existence-gated; variables so the harness can
# point them at fake dirs.
MAGPIE_TOOLCHAIN_DIRS="${MAGPIE_TOOLCHAIN_DIRS-/usr/libexec/gcc /usr/lib/gcc /usr/include}"
MAGPIE_TOOLCHAIN_DIRS_DARWIN="${MAGPIE_TOOLCHAIN_DIRS_DARWIN-/Library/Developer/CommandLineTools}"

# dpkg's package status DB: readable so start.R's requirements check
# (dpkg-query) sees the installed system libraries instead of
# reporting them missing. Harness-overridable like the toolchain.
MAGPIE_DPKG_DIRS="${MAGPIE_DPKG_DIRS-/var/lib/dpkg}"

MAGPIE_HANDLE_FILE="$HOME/.magpie-course-handle"

# Bump when the generated magpie-profile content changes: profiles
# written by an older script version are detected by the marker in
# meta.description and regenerated (old copy kept as .bak).
MAGPIE_PROFILE_SCHEMA="10"

# Deterministic madrat mainfolder + renv cache folder. The nono profile
# allows writes in them and the sandboxed children get them passed in,
# so the values stay fixed (not env-overridable).
MADRAT_MAINFOLDER="$HOME/.madrat"
RENV_PATHS_CACHE="$HOME/.cache/R/renv"
export MADRAT_MAINFOLDER RENV_PATHS_CACHE

# ---------------- screen, log ----------------

magpie_now() {
  date +%H:%M:%S
}

# Screen output: fd 4 is the real terminal (saved at entry).
magpie_say() {
  printf '%s\n' "$1" >&4
}

# Heads-up before a slow step that actually runs.
magpie_say_progress() {
  magpie_say "[$(magpie_now)] - installing $1, $2..."
}

# Everything else goes to the log (main's stdout).
magpie_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# ---------------- code name + live feed ----------------

# One small pseudo-random number from the system entropy source.
magpie_rand() {
  r=$(od -An -tu2 -N2 /dev/urandom | tr -d ' ')
  if [ -z "$r" ]; then
    r=7
  fi
  printf '%s\n' "$r"
}

# First 12 hex of the file's sha256 ("" if the tools are missing).
# The two teacher fill-ins are MASKED before hashing, so every filled
# copy of one build shares one hash: the STATUS_URL line (WebDAV
# credentials) becomes a constant, the COURSE_GAMSLICE heredoc body
# (pasted licence) is dropped with only its markers kept. A truncated
# licence loses the closing marker and still hashes differently; edits
# or truncation anywhere else do too. awk is already required by
# magpie_sanitize, so the sandbox profile gains nothing new.
# uname, not $MAGPIE_OS: runs before the OS is set.
magpie_setup_version() {
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    return 0
  fi
  command -v awk >/dev/null 2>&1 || return 0
  awk '
    /^STATUS_URL=/ { print "STATUS_URL=\"<FEED>\""; next }
    /^[ \t]*cat <<.COURSE_GAMSLICE.$/ { print; fill = 1; next }
    fill { if (/^COURSE_GAMSLICE$/) { fill = 0; print } next }
    { print }
  ' "$1" | {
    if [ "$(uname)" = "Darwin" ]; then
      shasum -a 256 2>/dev/null
    else
      sha256sum 2>/dev/null
    fi
  } | cut -d ' ' -f 1 | cut -c1-12
}

# magpie_pick <r1> <r2> <animal>...: Animal+3digits from two randoms.
magpie_pick() {
  r1=$1
  r2=$2
  shift 2
  idx=$((r1 % $# + 1))
  num=$((100 + r2 % 900))
  i=0
  for a
  do
    i=$((i + 1))
    if [ "$i" = "$idx" ]; then
      printf '%s%s\n' "$a" "$num"
      return 0
    fi
  done
  return 1
}

# Handle file = Animal+3digits, created once, reused forever. Internal
# per-machine id for feed posts and the username replacement; no prompt.
magpie_init_handle() {
  if [ -f "$MAGPIE_HANDLE_FILE" ]; then
    MAGPIE_HANDLE=$(cat "$MAGPIE_HANDLE_FILE" 2>/dev/null || true)
    if [ -n "$MAGPIE_HANDLE" ]; then
      return 0
    fi
    # Present but unreadable or empty (a sandboxed child with a stale
    # profile): fall through and run under a fresh name instead of an
    # empty one.
  fi
  new_handle=$(magpie_pick "$(magpie_rand)" "$(magpie_rand)" \
    Fox Otter Zebra Gecko Panda Koala Walrus Lynx Heron Bison \
    Mantis Puffin Cobra Yak Lemur Impala Orca Badger Falcon Manatee \
    Tapir Sloth Okapi Pangolin Narwhal Coyote Ibex Quokka Dingo Gibbon \
    Tarsier Jerboa Kestrel Marmot Ocelot Platypus Rhea Urchin Vulture \
    Wombat Toad Crane Hare Eagle Snake Turtle Parrot Hedgehog Beaver \
    Llama Alpaca Toucan Pelican Ferret)
  # Atomic first creation: two concurrent first runs converge on one
  # name; the loser keeps the winner's handle. An EMPTY or UNREADABLE
  # existing file (stale-profile child) still yields the fresh name:
  # the creation failed because the file exists, so the read alone must
  # never decide - and no cat: error may reach the caller.
  if ! ( set -C; printf '%s\n' "$new_handle" > "$MAGPIE_HANDLE_FILE" ) 2>/dev/null; then
    MAGPIE_HANDLE=$(cat "$MAGPIE_HANDLE_FILE" 2>/dev/null || true)
    if [ -z "$MAGPIE_HANDLE" ]; then
      MAGPIE_HANDLE=$new_handle
    fi
    return 0
  fi
  MAGPIE_HANDLE=$new_handle
}

# Log-only: the code name reaches the student on screen in the
# `system: ... | code name: ...` check header and in the failure
# verdict, so greeting them with it would only add a line.
magpie_greet() {
  magpie_init_handle
  magpie_log "reporting status as $MAGPIE_HANDLE"
}

# The account's real name from the user database ("" if unavailable).
magpie_realname() {
  if [ "$(uname)" = "Darwin" ]; then
    command -v dscacheutil >/dev/null 2>&1 || return 0
    dscacheutil -q user -a "$(id -un 2>/dev/null)" 2>/dev/null \
      | sed -n 's/^realname: //p' | head -n 1
  else
    command -v getent >/dev/null 2>&1 || return 0
    getent passwd "$(id -u)" 2>/dev/null | cut -d: -f5 | cut -d, -f1
  fi
}

# PII choke point for every feed upload: replaces $HOME, hostname and
# username. The username becomes the code name (same token as the feed
# header). Best effort against arbitrary child output; order matters
# (a hostname can contain the username). Literal, token-boundary
# matching: no regex metachars, and short names like "pi" never hit
# inside unrelated words. The ".local" suffix (macOS mDNS hostnames) is
# filtered in both shapes; the real name too, when the OS exposes it.
magpie_sanitize() {
  awk -v home="$HOME" -v host="$(uname -n 2>/dev/null)" \
    -v user="$(id -un 2>/dev/null)" -v real="$(magpie_realname)" \
    -v handle="${MAGPIE_HANDLE:-unknown}" '
  function litrep(s, old, new,   p, b, a, out) {
    if (length(old) < 2) {
      return s
    }
    out = ""
    while ((p = index(s, old)) > 0) {
      b = (p == 1) ? "" : substr(s, p - 1, 1)
      a = substr(s, p + length(old), 1)
      out = out substr(s, 1, p - 1)
      if (b ~ /[A-Za-z0-9._-]/ || a ~ /[A-Za-z0-9._-]/) {
        out = out old
      } else {
        out = out new
      }
      s = substr(s, p + length(old))
    }
    return out s
  }
  {
    line = litrep($0, home, "~")
    line = litrep(line, host, "HOST")
    if (host ~ /\.local$/) {
      line = litrep(line, substr(host, 1, length(host) - 6), "HOST")
    }
    if (length(real) >= 3) {
      line = litrep(line, real, handle)
    }
    line = litrep(line, user, handle)
    print line
  }'
}

# Feed reachable? magpie_report silently skips without these, and
# magpie_fail must know: with no receiver the diagnostics stay on the
# student's screen instead of vanishing into the log.
magpie_feed_on() {
  [ -n "$STATUS_URL" ] && command -v curl >/dev/null 2>&1
}

# magpie_report "<text>": one upload into the feed folder, text may be
# multi-line. Header: "<handle> | <OS arch> | v<file hash> | <text>".
# Bodies stay under ~3.2 KB (the failure-post cap). Never fails the
# caller. -T sends PUT with a real Content-Length. The name holds date,
# time, pid and a per-run counter, so a PUT can never replace an earlier
# post (PUT overwrites on the WebDAV target).
magpie_report() {
  if ! magpie_feed_on; then
    return 0
  fi
  post_file=$(mktemp 2>/dev/null) || return 0
  MAGPIE_REPORT_SEQ=$((${MAGPIE_REPORT_SEQ:-0} + 1))
  printf '%s | %s %s | v%s | %s' "${MAGPIE_HANDLE:-unknown}" \
    "$(uname -s)" "$(uname -m)" "${MAGPIE_SETUP_VERSION:-unknown}" "$1" \
    | magpie_sanitize > "$post_file"
  curl -m 5 -s -o /dev/null -T "$post_file" \
    "$STATUS_URL/${MAGPIE_HANDLE:-unknown}-$(date +%Y%m%d-%H%M%S)-$$-$MAGPIE_REPORT_SEQ.log" || true
  rm -f "$post_file"
  return 0
}

# ---------------- error handling ----------------

magpie_sys_string() {
  # uname, not $MAGPIE_OS: magpie_fail can run before the OS is set.
  if [ "$(uname)" = "Darwin" ]; then
    printf 'macOS %s\n' "$(sw_vers -productVersion 2>/dev/null)"
  else
    grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f 2
  fi
}

# Final verdict: one screen verdict + feed post (log tail included) +
# exit 1. No AI help block and no ~/magpie/setup-help.txt: the student
# sends the code name, the TA reads the feed and this machine's log.
# Fix hints stay inside the step text (that is where the WSL/sudo hints
# already live). $1 step text, $2 check results ("").
magpie_fail() {
  step=$1
  results=${2:-}
  MAGPIE_FAIL_POSTED=1
  logfile="$HOME/magpie/setup-log.txt"
  # The log tail rides along (capped): whoever reads the feed needs the
  # context, not just the step name.
  detail=$(
    {
      printf 'System: %s | %s | code name: %s\n' \
        "$(magpie_sys_string)" "$(uname -m)" "${MAGPIE_HANDLE:-unknown}"
      if [ -n "$results" ]; then
        printf 'CHECK RESULTS:\n'
        printf '%s\n' "$results"
      else
        printf 'FAILED STEP (twice, reproducible): %s | %s\n' \
          "$step" "$(tail -n 1 "$logfile" 2>/dev/null)"
      fi
      printf -- '--- last 25 log lines ---\n'
      tail -n 25 "$logfile" 2>/dev/null
    } | head -c 3200
  )
  magpie_report "setup: FAIL $step
$detail"
  magpie_say ""
  magpie_say "SETUP FAILED (twice, reproducible): $step"
  if [ -n "$results" ]; then
    printf '%s\n' "$results" >&4
  fi
  if ! magpie_feed_on; then
    # Offline (or no curl): no feed for the TA to read, so the log tail
    # has to reach the screen instead.
    magpie_say "--- last 25 log lines ---"
    tail -n 25 "$logfile" >&4 2>/dev/null
  fi
  magpie_say "  your code name: ${MAGPIE_HANDLE:-unknown} - tell the TA this"
  magpie_say "  everything else: $logfile"
  exit 1
}

# Step still failing after retries: pass 1 -> one retry pass in a fresh
# process; pass 2 -> the failure verdict. Never a third pass.
magpie_step_failed() {
  step=$1
  magpie_log "step failed after retries: $step"
  if [ "${MAGPIE_PASS:-1}" = "2" ]; then
    magpie_fail "$step"
  fi
  magpie_report "setup: retry pass 2 after: $step"
  magpie_say "[$(magpie_now)] - something failed, retrying automatically in $MAGPIE_PASS_SECS s"
  sleep "$MAGPIE_PASS_SECS"
  if [ -n "${MAGPIE_SELF:-}" ]; then
    MAGPIE_PASS=2
    export MAGPIE_PASS
    # The new process must start with the real terminal, not the log.
    exec 1>&4 2>&4
    exec bash "$MAGPIE_SELF"
  fi
  MAGPIE_PASS=2
  magpie_setup_path
  exit 1
}

# retry N cmd args... - N attempts, wait between attempts.
magpie_retry() {
  count=$1
  shift
  attempt=0
  while :
  do
    attempt=$((attempt + 1))
    magpie_log "attempt $attempt/$count: $*"
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$count" ]; then
      return 1
    fi
    if [ "$attempt" -eq 1 ]; then
      sleep "$MAGPIE_RETRY_SECS"
    else
      sleep "$MAGPIE_RETRY_SECS2"
    fi
  done
}

# ---------------- sudo ----------------

magpie_start_keepalive() {
  pidfile="$HOME/magpie/.keepalive.pid"
  old=$(cat "$pidfile" 2>/dev/null || echo "")
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    return 0
  fi
  # 720 ticks (12 h cap) - long enough that no install step re-prompts;
  # the loop also ends once this script's process is gone. Watch $$,
  # not $PPID: bash keeps $PPID at the OUTER parent inside a subshell.
  owner=$$
  (
    trap - EXIT INT TERM
    parent=$owner
    i=0
    while [ "$i" -lt 720 ] && kill -0 "$parent" 2>/dev/null; do
      sleep "$MAGPIE_KEEPALIVE_SECS"
      sudo -n true >/dev/null 2>&1 || true
      i=$((i + 1))
    done
  ) >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$pidfile"
}

# Ask once, blind; retry loop; keep-alive only when a prompt happened.
magpie_sudo_warm() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  magpie_say "Your administrator password is asked now. Type it blind - nothing shows on screen."
  round=0
  while [ "$round" -lt 6 ]; do
    if sudo -v; then
      magpie_start_keepalive
      return 0
    fi
    round=$((round + 1))
    magpie_say "Password not accepted - try again"
    sleep "$MAGPIE_SUDO_RETRY_SECS"
  done
  magpie_fail "password was never accepted"
}

# ---------------- 9P relocation ----------------

# Students run this file from /mnt/c/Users/.../Downloads - a Windows
# drive WSL mounts via 9P (stat: v9fs). Landlock cannot reliably
# enforce on 9P, so a sandboxed re-execution of the script from there
# makes nono warn and can deny reads at random. The original stays
# untouched; everything that crosses into the sandbox (read_file
# entry, gate child, pass-2 re-exec) uses a native copy instead.
magpie_native_self_copy() {
  if [ -z "$MAGPIE_SELF" ]; then
    return 0
  fi
  # GNU stat -c; macOS stat takes -f %T without -c and fails here ->
  # no relocation there (and never v9fs anyway).
  fstype=$(stat -f -c %T "$MAGPIE_SELF" 2>/dev/null) || return 0
  case $fstype in
    v9fs|9p) ;;
    *) return 0 ;;
  esac
  dest="$HOME/.magpie-course/self/setup-magpie.sh"
  # Without the native copy the sandboxed steps would still read the
  # 9P file (random denials, nono warnings). Rare - the folder sits in
  # $HOME, which is writable in every run that got this far - but when
  # folder or copy fails, the log has to say so. The teacher's copy of
  # this script carries the feed credentials and the licence, and 9P
  # sources are world-readable with a default 022 umask - so folder
  # (700) and copy (600) are forced private on EVERY relocation (cp -f
  # recreates the file, a one-time chmod would not survive reruns).
  if mkdir -p "$HOME/.magpie-course/self" 2>/dev/null \
    && chmod 700 "$HOME/.magpie-course/self" 2>/dev/null \
    && cp -f "$MAGPIE_SELF" "$dest" 2>/dev/null \
    && chmod 600 "$dest" 2>/dev/null; then
    MAGPIE_SELF=$dest
    magpie_log "script run from a Windows drive (9P) - sandboxed steps use $dest"
  else
    magpie_log "9P relocation copy failed - sandboxed steps still use the Windows path"
  fi
}

# ---------------- lock + traps ----------------

magpie_arm_traps() {
  trap 'exit 130' INT TERM
  trap 'magpie_cleanup' EXIT
}

magpie_stop_keepalive() {
  pidfile="$HOME/magpie/.keepalive.pid"
  if [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
    fi
    rm -f "$pidfile"
  fi
  # Killing the refresher alone is not enough: sudo remembers the
  # password for minutes after. -k drops the cached credential (never
  # prompts itself) so no warm sudo survives into a sandboxed run.
  command -v sudo >/dev/null 2>&1 && sudo -k >/dev/null 2>&1 || true
}

# A crash must leave no foreign files in ~/magpie (magpie clone guard).
# Only the lock owner may clean: a second window that exits with
# "already running" must not touch the FIRST run's downloads or
# keep-alive. keep-alive and setup-dl-* only ever exist once the lock
# is held, so ownership gating loses nothing.
magpie_cleanup() {
  # Unexpected exit: report it - a silent crash would look like a
  # healthy run on the feed. 0/130 = clean/abort, 1 after a FAIL post
  # is magpie_fail's own exit; the check-only child reports via the
  # gate instead.
  code=$?
  if [ -z "${MAGPIE_CHECK_ONLY:-}" ] && [ "$code" != 0 ] && [ "$code" != 130 ] \
    && { [ "$code" != 1 ] || [ "${MAGPIE_FAIL_POSTED:-}" != 1 ]; }; then
    magpie_report "$(printf 'setup: CRASH exit=%s\n%s' "$code" \
      "$(tail -n 10 "$HOME/magpie/setup-log.txt" 2>/dev/null | head -c 3200)")"
  fi
  lock="$HOME/magpie/.setup.lock"
  if [ -f "$lock/pid" ] && [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then
    magpie_stop_keepalive
    for leftover in "$HOME/magpie"/setup-dl-*; do
      rm -f "$leftover"
    done
    rm -rf "$lock"
  fi
}

magpie_take_lock() {
  lock="$HOME/magpie/.setup.lock"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    magpie_arm_traps
    return 0
  fi
  pid=$(cat "$lock/pid" 2>/dev/null || echo "")
  if [ "$pid" = "$$" ]; then
    magpie_arm_traps
    return 0
  fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    magpie_say "setup is already running in another window"
    exit 0
  fi
  rm -rf "$lock" 2>/dev/null
  if ! mkdir "$lock" 2>/dev/null; then
    magpie_fail "setup lock could not be created"
  fi
  printf '%s\n' "$$" > "$lock/pid"
  magpie_arm_traps
}

# ---------------- disk + pins ----------------

# Two tiers: below ABORT the failure verdict stops the run; below WARN the
# feed sees a warning but the run continues.
magpie_check_disk() {
  free_kb=$(df -Pk "$HOME/magpie" | awk 'NR==2 {print $4}')
  free_gb=$((free_kb / 1024 / 1024))
  if [ "$free_gb" -lt "$MAGPIE_DISK_ABORT_GB" ]; then
    if [ "$MAGPIE_OS" = "darwin" ]; then
      magpie_fail "low disk (${free_gb} GB free - empty the Trash and delete big files)"
    fi
    magpie_fail "low disk (${free_gb} GB free - free space in WINDOWS (C: drive) first)"
  fi
  if [ "$free_gb" -lt "$MAGPIE_DISK_WARN_GB" ]; then
    magpie_say "WARNING: only $free_gb GB disk free - MAgPIE needs about $MAGPIE_DISK_WARN_GB GB."
    if [ "$MAGPIE_OS" = "darwin" ]; then
      magpie_say "Free space now (empty Trash, delete big downloads), then continue."
    else
      magpie_say "On WSL free space on the WINDOWS side (C: drive), not inside Ubuntu."
    fi
    magpie_report "setup: WARNING low disk ${free_gb}G"
  else
    magpie_log "disk: $free_gb GB free"
  fi
}

magpie_require_pins() {
  for v in "$OPENCODE_VERSION" "$OPENCODE_SHA256_DARWIN_ARM64" \
    "$OPENCODE_SHA256_DARWIN_X64" "$OPENCODE_SHA256_LINUX_ARM64" \
    "$OPENCODE_SHA256_LINUX_X64" "$NONO_VERSION" "$NONO_PACK_VERSION" \
    "$NONO_SHA256_AARCH64_APPLE_DARWIN" "$NONO_SHA256_X86_64_APPLE_DARWIN" \
    "$NONO_SHA256_AARCH64_UNKNOWN_LINUX_GNU" "$NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU" \
    "$GAMS_VERSION" "$GAMS_URL_LINUX_X64" "$GAMS_SHA256_LINUX_X64" \
    "$GAMS_URL_DARWIN_ARM64" "$GAMS_SHA256_DARWIN_ARM64" \
    "$GAMS_URL_DARWIN_X64" "$GAMS_SHA256_DARWIN_X64" \
    "$GFORTRAN_VERSION" "$GFORTRAN_URL" "$GFORTRAN_SHA256" \
    "$R_VERSION" "$R_URL_DARWIN_ARM64" "$R_SHA256_DARWIN_ARM64" \
    "$R_URL_DARWIN_X64" "$R_SHA256_DARWIN_X64" \
    "$PANDOC_VERSION" "$PANDOC_URL_DARWIN_ARM64" "$PANDOC_SHA256_DARWIN_ARM64" \
    "$PANDOC_URL_DARWIN_X64" "$PANDOC_SHA256_DARWIN_X64"; do
    if [ -z "$v" ] || [ "$v" = "TBD" ]; then
      magpie_fail "script incomplete: pinned versions/checksums missing"
    fi
  done
}

# ---------------- shared tool helpers ----------------

magpie_sha256() {
  if [ "$MAGPIE_OS" = "darwin" ]; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    sha256sum "$1" | cut -d ' ' -f 1
  fi
}

magpie_curl() {
  curl -sS -fL --retry 4 --retry-delay 5 --retry-all-errors \
    --connect-timeout 15 --max-time 900 "$@"
}

# magpie_download url out expected_sha - reuse intact temp, else resume.
# An intact temp file (killed run after download, before cleanup) skips
# the request; a failed attempt drops the temp so no resume can wedge on
# a complete-but-wrong file (curl 416). Checksum decides correctness.
magpie_download() {
  if [ -f "$2" ] && [ "$(magpie_sha256 "$2")" = "$3" ]; then
    magpie_log "download skipped, temp file intact: $1"
    return 0
  fi
  if ! magpie_curl -C - -o "$2" "$1"; then
    rm -f "$2"
    magpie_log "download failed: $1"
    return 1
  fi
  if [ "$(magpie_sha256 "$2")" != "$3" ]; then
    magpie_log "checksum mismatch: $1"
    rm -f "$2"
    return 1
  fi
  return 0
}

# True when an rc PATH line already carries dir as its own entry. A
# plain substring grep would also match comments and longer paths
# ("/usr/local/bin/foo" hiding "/usr/local/bin").
magpie_rc_has_path() {
  awk -v d="$2" -v q="'" '
    $0 ~ /^[ \t]*#/ { next }
    !found && /PATH/ {
      s = $0
      while ((p = index(s, d)) > 0) {
        b = (p == 1) ? "" : substr(s, p - 1, 1)
        a = substr(s, p + length(d), 1)
        if ((b == ":" || b == "=" || b == "\"" || b == q || b == "/") &&
            (a == "" || a == ":" || a == "\"" || a == q)) {
          found = 1
          break
        }
        s = substr(s, p + length(d))
      }
    }
    END { exit !found }
  ' "$1" 2>/dev/null
}

# Appending to an rc whose last line has no final newline would merge
# the two lines and break both - close the open line first.
magpie_rc_newline() {
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
    printf '\n' >> "$1"
  fi
}

# rc_add_path <rc> <dir>: one PATH line per dir, exported into this run.
magpie_rc_add_path() {
  rc=$1
  dir=$2
  touch "$rc" 2>/dev/null || true
  if magpie_rc_has_path "$rc" "$dir"; then
    export PATH="$dir:$PATH"
    return 1
  fi
  magpie_rc_newline "$rc"
  # shellcheck disable=SC2016  # $PATH must stay literal in the rc line.
  printf 'export PATH="%s:$PATH"\n' "$dir" >> "$rc"
  export PATH="$dir:$PATH"
  return 0
}

magpie_fix_bin_path() {
  bin=$1
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi
  for dir in "$HOME/.opencode/bin" "$HOME/.nono/bin" "$HOME/.local/bin" \
    /usr/local/bin /opt/homebrew/bin; do
    if [ -x "$dir/$bin" ]; then
      if magpie_rc_add_path "$MAGPIE_RC" "$dir"; then
        magpie_log "added $bin to PATH in $MAGPIE_RC (also active in this run)"
      fi
      return 0
    fi
  done
  magpie_fail "$bin binary not found after install (install step failed)"
}

magpie_resolve_opencode() {
  found=$(command -v opencode 2>/dev/null) || found=""
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  if [ -x "$HOME/.opencode/bin/opencode" ]; then
    printf '%s\n' "$HOME/.opencode/bin/opencode"
    return 0
  fi
  return 1
}

magpie_resolve_nono() {
  found=$(command -v nono 2>/dev/null) || found=""
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  if [ -x "$HOME/.nono/bin/nono" ]; then
    printf '%s\n' "$HOME/.nono/bin/nono"
    return 0
  fi
  return 1
}

# magpie_install_pkg <name> <url> <sha>: download a pinned .pkg under
# ~/magpie (setup-dl-*), install it system-wide. sudo only when it runs.
# The sha is re-checked right before sudo reads the file (root must
# never read a file that changed after verification).
magpie_install_pkg() {
  pkg="$HOME/magpie/setup-dl-$1.pkg"
  magpie_download "$2" "$pkg" "$3" || return 1
  if [ "$(magpie_sha256 "$pkg")" != "$3" ]; then
    magpie_log "checksum re-check failed before installer: $pkg"
    rm -f "$pkg"
    return 1
  fi
  magpie_sudo_warm || return 1
  if ! sudo installer -pkg "$pkg" -target /; then
    return 1
  fi
  rm -f "$pkg"
}

# ---------------- OS branches (before the tools) ----------------

magpie_apt_body() {
  magpie_sudo_warm || return 1
  # Lock timeout: WSL's unattended-upgrades can hold the dpkg lock
  # far past the step retries.
  sudo apt-get -o DPkg::Lock::Timeout=120 update || return 1
  sudo apt-get -o DPkg::Lock::Timeout=120 install -y -o Acquire::Retries=3 \
    git curl || return 1
  command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1
}

magpie_clt_body() {
  magpie_sudo_warm || return 1
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.txt
  label=$(softwareupdate --list 2>&1 \
    | sed -n 's/^[*[:space:]]*Label: //p' \
    | grep "Command Line Tools" | tail -n 1)
  if [ -z "$label" ]; then
    magpie_log "no Command Line Tools label in softwareupdate --list"
    return 1
  fi
  sudo softwareupdate --install "$label" || return 1
  git --version >/dev/null 2>&1
}

magpie_step_os_base() {
  if [ "$MAGPIE_OS" = "linux" ]; then
    if command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
      magpie_log "git + curl present - apt not needed"
      return 0
    fi
    magpie_say_progress "git + curl" "about 1-2 min"
    if ! magpie_retry 3 magpie_apt_body; then
      magpie_step_failed "apt git curl"
    fi
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    magpie_fail "system curl missing (/usr/bin/curl expected)"
  fi
  if xcode-select -p >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    magpie_log "Xcode CLT + git present"
    return 0
  fi
  magpie_say_progress "Xcode Command Line Tools" "about 5-20 min, please wait"
  if ! magpie_retry 3 magpie_clt_body; then
    magpie_step_failed "Xcode Command Line Tools"
  fi
}

# ---------------- opencode ----------------

# exit 2: no AVX2 (baseline build). exit 3: musl libc. Both unsupported here.
magpie_opencode_target() {
  case $(uname -m) in
    arm64|aarch64) arch=arm64 ;;
    x86_64) arch=x64 ;;
    *) return 1 ;;
  esac
  if [ "$arch" = "x64" ]; then
    if [ "$MAGPIE_OS" = "linux" ]; then
      grep -q avx2 /proc/cpuinfo 2>/dev/null || return 2
    else
      [ "$(sysctl -n hw.optional.avx2_0 2>/dev/null)" = "1" ] || return 2
    fi
  fi
  if [ "$MAGPIE_OS" = "linux" ] && ldd --version 2>&1 | grep -qi musl; then
    return 3
  fi
  printf '%s-%s\n' "$MAGPIE_OS" "$arch"
}

magpie_install_opencode_body() {
  tmp="$HOME/magpie/opencode-dl.tgz"
  dir="$HOME/magpie/opencode-extract"
  rm -rf "$dir"
  mkdir -p "$dir" || return 1
  url="https://registry.npmjs.org/@opencode%2fcli-$MAGPIE_OC_TARGET/-/cli-$MAGPIE_OC_TARGET-$OPENCODE_VERSION.tgz"
  magpie_download "$url" "$tmp" "$MAGPIE_OC_SHA" || return 1
  tar -xzf "$tmp" -C "$dir" package/bin/opencode || return 1
  mkdir -p "$HOME/.opencode/bin"
  mv "$dir/package/bin/opencode" "$HOME/.opencode/bin/opencode" || return 1
  chmod 755 "$HOME/.opencode/bin/opencode"
  rm -rf "$dir"
  rm -f "$tmp"
}

magpie_install_opencode() {
  if magpie_resolve_opencode >/dev/null; then
    magpie_log "opencode: already installed - keeping it"
    magpie_fix_bin_path opencode
    return 0
  fi
  if ! MAGPIE_OC_TARGET=$(magpie_opencode_target); then
    magpie_fail "opencode: unsupported CPU/libc variant (no pinned build)"
  fi
  case $MAGPIE_OC_TARGET in
    darwin-arm64) MAGPIE_OC_SHA=$OPENCODE_SHA256_DARWIN_ARM64 ;;
    darwin-x64) MAGPIE_OC_SHA=$OPENCODE_SHA256_DARWIN_X64 ;;
    linux-arm64) MAGPIE_OC_SHA=$OPENCODE_SHA256_LINUX_ARM64 ;;
    linux-x64) MAGPIE_OC_SHA=$OPENCODE_SHA256_LINUX_X64 ;;
  esac
  magpie_say_progress "opencode" "about 1 min"
  if ! magpie_retry 3 magpie_install_opencode_body; then
    magpie_step_failed "opencode install"
  fi
  magpie_fix_bin_path opencode
  magpie_say "OK: opencode $OPENCODE_VERSION installed"
  magpie_report "setup: opencode installed"
}

# ---------------- nono ----------------

magpie_nono_triple() {
  case $(uname -m) in
    arm64|aarch64) rust=aarch64 ;;
    x86_64) rust=x86_64 ;;
    *) return 1 ;;
  esac
  if [ "$MAGPIE_OS" = "darwin" ]; then
    printf '%s-apple-darwin\n' "$rust"
  else
    printf '%s-unknown-linux-gnu\n' "$rust"
  fi
}

magpie_install_nono_body() {
  tmp="$HOME/magpie/nono-dl.tar.gz"
  dir="$HOME/magpie/nono-extract"
  rm -rf "$dir"
  mkdir -p "$dir" || return 1
  url="https://github.com/nolabs-ai/nono/releases/download/v$NONO_VERSION/nono-v$NONO_VERSION-$MAGPIE_NONO_TRIPLE.tar.gz"
  magpie_download "$url" "$tmp" "$MAGPIE_NONO_SHA" || return 1
  member=$(tar -tzf "$tmp" | grep -E '(^|/)nono$' | head -n 1)
  if [ -z "$member" ]; then
    magpie_log "no nono executable in archive listing"
    return 1
  fi
  tar -xzf "$tmp" -C "$dir" "$member" || return 1
  mkdir -p "$HOME/.nono/bin"
  # curl does not set the quarantine xattr, so Gatekeeper stays quiet.
  mv "$dir/$member" "$HOME/.nono/bin/nono" || return 1
  chmod 755 "$HOME/.nono/bin/nono"
  rm -rf "$dir"
  rm -f "$tmp"
}

magpie_install_nono() {
  if magpie_resolve_nono >/dev/null; then
    magpie_log "nono: already installed - keeping it"
    magpie_fix_bin_path nono
    return 0
  fi
  if ! MAGPIE_NONO_TRIPLE=$(magpie_nono_triple); then
    magpie_fail "nono: unsupported CPU architecture $(uname -m)"
  fi
  case $MAGPIE_NONO_TRIPLE in
    aarch64-apple-darwin) MAGPIE_NONO_SHA=$NONO_SHA256_AARCH64_APPLE_DARWIN ;;
    x86_64-apple-darwin) MAGPIE_NONO_SHA=$NONO_SHA256_X86_64_APPLE_DARWIN ;;
    aarch64-unknown-linux-gnu) MAGPIE_NONO_SHA=$NONO_SHA256_AARCH64_UNKNOWN_LINUX_GNU ;;
    x86_64-unknown-linux-gnu) MAGPIE_NONO_SHA=$NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU ;;
  esac
  magpie_say_progress "nono" "about 1 min"
  if ! magpie_retry 3 magpie_install_nono_body; then
    magpie_step_failed "nono install"
  fi
  magpie_fix_bin_path nono
  magpie_say "OK: nono $NONO_VERSION installed"
  magpie_report "setup: nono installed"
}

# ---------------- opencode config ----------------

magpie_write_opencode_config() {
  file="$HOME/.config/opencode/opencode.json"
  mkdir -p "$HOME/.config/opencode" || return 1
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "hu/llm3",
  "providers": {
    "hu": {
      "name": "HU Berlin LLM3",
      "env": ["HU_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "https://llm3-compute.cms.hu-berlin.de/v1"
      },
      "models": {
        "llm3": {
          "modelID": "llm3",
          "body": {
            "chat_template_kwargs": { "enable_thinking": true }
          }
        }
      }
    }
  }
}
EOF
  if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
    magpie_log "opencode config already in place"
    rm -f "$tmp"
    return 0
  fi
  if [ -f "$file" ]; then
    cp "$file" "$file.bak"
    magpie_log "existing opencode config saved as $file.bak"
  fi
  mv "$tmp" "$file"
  magpie_log "wrote opencode config: $file"
}

# No launcher here, so students may start opencode from a fresh
# terminal later: the rc line must carry the placeholder key too.
magpie_register_hu_key() {
  touch "$MAGPIE_RC" 2>/dev/null || true
  if ! grep -q '^export HU_API_KEY=' "$MAGPIE_RC" 2>/dev/null; then
    magpie_rc_newline "$MAGPIE_RC"
    printf 'export HU_API_KEY="required-but-not-used"\n' >> "$MAGPIE_RC"
    magpie_log "HU_API_KEY exported to $MAGPIE_RC"
  fi
}

# The nono profile grants write to these two folders, so the folder tree
# must exist before any sandboxed child runs.
# tools::R_user_dir() folder trio (R's per-user cache/data/config
# roots). Packages write into them AT LOAD TIME (gdtools' font cache
# during ggiraph's lazy load died on exactly this), so the sandboxed
# children need them readable AND writable; magpie_register_caches
# creates them before the profile step.
magpie_r_user_dirs() {
  if [ "${MAGPIE_OS:-}" = "darwin" ]; then
    printf '%s\n' "$HOME/Library/Caches/org.R-project.R" \
      "$HOME/Library/Application Support/org.R-project.R" \
      "$HOME/Library/Preferences/org.R-project.R"
  else
    printf '%s\n' "$HOME/.cache/R" "$HOME/.local/share/R" "$HOME/.config/R"
  fi
}

magpie_register_caches() {
  mkdir -p "$MADRAT_MAINFOLDER" "$RENV_PATHS_CACHE" || return 1
  # Subshell + newline IFS: one mkdir per path (macOS "Application
  # Support" has a space) with no process substitution, and a failed
  # mkdir returns without leaving the modified IFS behind.
  ( IFS='
'
    for d in $(magpie_r_user_dirs); do
      mkdir -p "$d" || exit 1
    done ) || return 1
  touch "$MAGPIE_RC" 2>/dev/null || true
  if ! grep -q '^export MADRAT_MAINFOLDER=' "$MAGPIE_RC" 2>/dev/null; then
    magpie_rc_newline "$MAGPIE_RC"
    printf 'export MADRAT_MAINFOLDER="%s"\n' "$MADRAT_MAINFOLDER" >> "$MAGPIE_RC"
    magpie_log "MADRAT_MAINFOLDER exported to $MAGPIE_RC"
  fi
  if ! grep -q '^export RENV_PATHS_CACHE=' "$MAGPIE_RC" 2>/dev/null; then
    magpie_rc_newline "$MAGPIE_RC"
    printf 'export RENV_PATHS_CACHE="%s"\n' "$RENV_PATHS_CACHE" >> "$MAGPIE_RC"
    magpie_log "RENV_PATHS_CACHE exported to $MAGPIE_RC"
  fi
}

# ---------------- course tools ----------------

magpie_have_r() {
  command -v Rscript >/dev/null 2>&1 && \
    Rscript --vanilla -e 'quit(status = if (getRversion() >= "4.3") 0 else 1)' 2>/dev/null
}

# R's own Fortran compiler, printed only when it really is executable;
# empty otherwise. Ask R, never guess the path: `R CMD config FC` reports
# the compiler R was configured with (plus -arch flags after it), so it is
# the only probe that can tell a usable compiler from a folder that merely
# exists. Absolute FC entries are access-checked directly, bare ones
# (e.g. plain "gfortran") go through Sys.which first. Never fails the
# caller: an R without a Fortran, a broken FC string or a failing Rscript
# all come back empty.
magpie_r_fc() {
  fc=$(Rscript --vanilla -e 'fc <- suppressWarnings(system("R CMD config FC 2>/dev/null", intern = TRUE))
w <- scan(text = paste(fc, collapse = " "), what = "", quiet = TRUE)
if (!length(w)) quit(status = 1)
p <- w[1]
if (!grepl("/", p)) { s <- Sys.which(p); if (!nzchar(s[1])) quit(status = 1); p <- s[1] }
if (file.access(p, 1) == 0) cat(p)' 2>/dev/null) || fc=""
  printf '%s\n' "$fc"
}

# Is a usable gfortran there? With R installed, R's own FC is the only
# test that matters (a PATH-provided gfortran is covered: FC then resolves
# through Sys.which). Without R (this step runs BEFORE magpie_step_r on a
# fresh machine) fall back to the plain probes: PATH, then the modern pkg
# target, then the legacy 6.x-era tree. The 2026-11 loop was exactly this
# probe missing /opt: the 14.2 pkg installed fine, the check looked at
# /usr/local and reinstalled it until the step failed.
magpie_have_gfortran() {
  if command -v Rscript >/dev/null 2>&1; then
    if [ -n "$(magpie_r_fc)" ]; then
      return 0
    fi
    return 1
  fi
  command -v gfortran >/dev/null 2>&1 \
    || [ -x "$MAGPIE_GFORTRAN_DIR_NEW/bin/gfortran" ] \
    || [ -x "$MAGPIE_GFORTRAN_DIR/bin/gfortran" ]
}

# gfortran is usually NOT on PATH: register the bin dir holding it for
# this run + the rc, or renv restore compiles and the sandboxed children
# never find a Fortran compiler. R's FC dir wins when FC resolved; else
# the dir the fallback probe actually found a gfortran in (modern pkg
# target first, legacy tree next), so the registered dir is never one
# that holds nothing. Reached only when magpie_have_gfortran was true.
magpie_register_gfortran() {
  if command -v gfortran >/dev/null 2>&1; then
    return 0
  fi
  gdir=${MAGPIE_PKG_GDIR:-$MAGPIE_GFORTRAN_DIR_NEW}
  fc=$(magpie_r_fc)
  if [ -n "$fc" ]; then
    bin=$(dirname "$fc")
  elif [ -x "$gdir/bin/gfortran" ]; then
    bin="$gdir/bin"
  elif [ -x "$MAGPIE_GFORTRAN_DIR/bin/gfortran" ]; then
    bin="$MAGPIE_GFORTRAN_DIR/bin"
  else
    bin="$gdir/bin"
  fi
  if magpie_rc_add_path "$MAGPIE_RC" "$bin"; then
    magpie_log "gfortran registered in $MAGPIE_RC + this run"
  fi
}

# The -dev library list for R package compilation. Ubuntu 26.04+
# marks the libcurl4-*-dev flavours as conflicting - request the
# openssl one only (renv builds the R curl/httr stack against it).
magpie_apt_tools_install() {
  sudo apt-get -o DPkg::Lock::Timeout=120 install -y -o Acquire::Retries=3 \
    git wget zip unzip r-base pandoc build-essential cmake gfortran \
    gdal-bin libcurl4-openssl-dev \
    libfontconfig1 libfontconfig1-dev libfreetype-dev libfribidi-dev \
    libgdal-dev libgit2-dev libglpk-dev libharfbuzz-dev libjpeg-dev \
    libnetcdf-dev libpng-dev libpoppler-cpp-dev libcairo2-dev libssl-dev \
    libtiff5-dev libudunits2-dev libxml2-dev libuv1-dev pari-gp qpdf
}

# Ubuntu ships an R too old for magpie before 24.04 (22.04: 4.1.x) -
# say so up front instead of failing at the checks much later.
magpie_ubuntu_floor() {
  rel="${MAGPIE_OS_RELEASE:-/etc/os-release}"
  id=$(sed -n 's/^ID=//p' "$rel" 2>/dev/null | tr -d '"')
  ver=$(sed -n 's/^VERSION_ID=//p' "$rel" 2>/dev/null | tr -d '"')
  major=${ver%%.*}
  [ "$id" = "ubuntu" ] || return 0
  case $major in
    ""|*[!0-9]*) return 0 ;;
  esac
  if [ "$major" -lt 24 ]; then
    magpie_fail "Ubuntu $ver ships an R older than 4.3 - use Ubuntu 24.04+ (in WSL: wsl --install -d Ubuntu-24.04)"
  fi
}

# Representative subset of the -dev/build package list below: an old
# install that predates them must not skip the apt step (renv compile
# of sf/terra would fail later). dpkg -s is also true for known-but-
# broken packages, so require the "install ok installed" status line.
magpie_apt_have_devlibs() {
  for pkg in build-essential cmake gfortran libudunits2-dev libgdal-dev \
    libcurl4-openssl-dev libgit2-dev libglpk-dev libxml2-dev; do
    status=$(dpkg -s "$pkg" 2>/dev/null) || return 1
    case $status in
      *"Status: install ok installed"*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Linux: base tools + the -dev libraries R packages compile against,
# one apt call. Skip when R, pandoc AND the build libraries are all
# there. A failed install often means a stale image: runtime libs
# older than the -dev candidates. One dist-upgrade, then retry the
# same install.
magpie_apt_tools_body() {
  magpie_sudo_warm || return 1
  sudo apt-get -o DPkg::Lock::Timeout=120 update || return 1
  if ! magpie_apt_tools_install; then
    magpie_log "bulk install failed - retrying after dist-upgrade"
    sudo apt-get -o DPkg::Lock::Timeout=120 dist-upgrade -y \
      -o Acquire::Retries=3 || return 1
    magpie_apt_tools_install || return 1
  fi
  # Pandoc AND a new-enough R: an apt r-base older than 4.3 must not
  # read as success here (it would only fail at the checks later).
  command -v pandoc >/dev/null 2>&1 && magpie_have_r
}

magpie_step_apt_tools() {
  magpie_ubuntu_floor
  if magpie_have_r && command -v pandoc >/dev/null 2>&1 \
    && magpie_apt_have_devlibs; then
    magpie_log "R + pandoc + build libraries present - apt tools step skipped"
    return 0
  fi
  magpie_say_progress "R, pandoc + support packages" "5-15 min, just wait"
  if ! magpie_retry 3 magpie_apt_tools_body; then
    magpie_step_failed "apt course tools"
  fi
  magpie_say "OK: R + support packages installed"
}

# macOS: three pinned .pkg steps, each skip-if-done. No Homebrew.
magpie_step_gfortran() {
  # This run's pkg target: what the pinned pkg installs into and what
  # magpie_register_gfortran falls back to when R has no FC to ask.
  MAGPIE_PKG_GDIR=$MAGPIE_GFORTRAN_DIR_NEW
  MAGPIE_PKG_URL=$GFORTRAN_URL
  MAGPIE_PKG_SHA=$GFORTRAN_SHA256
  if magpie_have_gfortran; then
    magpie_log "gfortran: present"
    magpie_register_gfortran
    return 0
  fi
  magpie_say_progress "gfortran $GFORTRAN_VERSION" "about 2-5 min"
  if ! magpie_retry 3 magpie_gfortran_body; then
    magpie_step_failed "gfortran install"
  fi
  magpie_register_gfortran
  magpie_say "OK: gfortran installed"
}

magpie_gfortran_body() {
  # ${...:-} so a standalone body call (harness, reruns) stays sane
  # under set -u when the step did not set the target.
  magpie_log "gfortran install attempt: gfortran-$GFORTRAN_VERSION-universal.pkg, FC target ${MAGPIE_PKG_GDIR:-$MAGPIE_GFORTRAN_DIR_NEW}/bin"
  magpie_install_pkg gfortran "$MAGPIE_PKG_URL" "$MAGPIE_PKG_SHA" || return 1
  if magpie_have_gfortran; then
    return 0
  fi
  # The installer reported success and R still has no usable Fortran
  # compiler: one line of real state (what FC resolves to + what the two
  # pkg targets actually hold) belongs in the log, or the feed's 25-line
  # tail shows nothing but repeated identical `installer:` stanzas - that
  # is how the 2026-11 loop stayed unreadable. Listing failures never
  # change the verdict: the pipelines end in tr, and 1 is returned here.
  # shellcheck disable=SC2012  # one-line listing for a log line, not parsing.
  ls_new=$(ls "$MAGPIE_GFORTRAN_DIR_NEW/bin" 2>/dev/null | tr '\n' ' ')
  # shellcheck disable=SC2012
  ls_old=$(ls "$MAGPIE_GFORTRAN_DIR/bin" 2>/dev/null | tr '\n' ' ')
  magpie_log "gfortran pkg installed, no usable FC: fc=$(magpie_r_fc) | new $MAGPIE_GFORTRAN_DIR_NEW/bin: ($ls_new) | legacy $MAGPIE_GFORTRAN_DIR/bin: ($ls_old)"
  return 1
}

magpie_step_r() {
  if magpie_have_r; then
    magpie_log "R: present (>= 4.3)"
    return 0
  fi
  case $(uname -m) in
    arm64) MAGPIE_PKG_URL=$R_URL_DARWIN_ARM64; MAGPIE_PKG_SHA=$R_SHA256_DARWIN_ARM64 ;;
    *) MAGPIE_PKG_URL=$R_URL_DARWIN_X64; MAGPIE_PKG_SHA=$R_SHA256_DARWIN_X64 ;;
  esac
  magpie_say_progress "R $R_VERSION" "about 2-5 min"
  if ! magpie_retry 3 magpie_r_body; then
    magpie_step_failed "R install"
  fi
  magpie_say "OK: R installed"
}

magpie_r_body() {
  magpie_install_pkg R "$MAGPIE_PKG_URL" "$MAGPIE_PKG_SHA" || return 1
  magpie_have_r
}

magpie_step_pandoc() {
  if command -v pandoc >/dev/null 2>&1; then
    magpie_log "pandoc: present"
    return 0
  fi
  case $(uname -m) in
    arm64) MAGPIE_PKG_URL=$PANDOC_URL_DARWIN_ARM64; MAGPIE_PKG_SHA=$PANDOC_SHA256_DARWIN_ARM64 ;;
    *) MAGPIE_PKG_URL=$PANDOC_URL_DARWIN_X64; MAGPIE_PKG_SHA=$PANDOC_SHA256_DARWIN_X64 ;;
  esac
  magpie_say_progress "pandoc $PANDOC_VERSION" "about 1-2 min"
  if ! magpie_retry 3 magpie_pandoc_body; then
    magpie_step_failed "pandoc install"
  fi
  magpie_say "OK: pandoc installed"
}

magpie_pandoc_body() {
  magpie_install_pkg pandoc "$MAGPIE_PKG_URL" "$MAGPIE_PKG_SHA" || return 1
  command -v pandoc >/dev/null 2>&1
}

magpie_step_course_tools() {
  if [ "$MAGPIE_OS" = "linux" ]; then
    magpie_step_apt_tools
    return 0
  fi
  magpie_step_gfortran
  magpie_step_r
  magpie_step_pandoc
}

# ---------------- TinyTeX + tex PATH ----------------

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

magpie_step_tinytex() {
  # Skip only when a working tex exists (PATH or complete TinyTeX
  # folder): a dir from a killed run must NOT block the reinstall
  # forever. Empty output, not exit status: an empty glob loop
  # returns 0.
  if [ -n "$(magpie_texbin)" ]; then
    magpie_log "TinyTeX: already installed"
  else
    # No usable tex anywhere: any TinyTeX root that exists is an
    # incomplete leftover of a killed run - clear both install spots.
    for root in "$HOME/Library/TinyTeX" "$HOME/.TinyTeX"; do
      if [ -d "$root" ]; then
        magpie_log "TinyTeX: incomplete folder found - reinstalling"
        rm -rf "$root"
      fi
    done
    magpie_say_progress "TinyTeX" "a few minutes"
    if ! magpie_retry 3 magpie_tinytex_body; then
      magpie_step_failed "TinyTeX install"
    fi
    magpie_say "OK: TinyTeX installed"
  fi
  magpie_register_tex
}

# The tex directory: from PATH, else a TinyTeX bin holding tex.
# tinytex::install_tinytex() uses ~/Library/TinyTeX on macOS and
# ~/.TinyTeX on Linux - both roots are searched on every OS.
magpie_texbin() {
  texbin=$(dirname "$(command -v tex 2>/dev/null || echo /nonexistent)")
  if [ -x "$texbin/tex" ]; then
    printf '%s\n' "$texbin"
    return 0
  fi
  for root in "$HOME/Library/TinyTeX" "$HOME/.TinyTeX"; do
    for d in "$root"/bin/*/; do
      if [ -x "${d}tex" ]; then
        printf '%s\n' "${d%/}"
        return 0
      fi
    done
  done
}

# The tinytex installer only edits rc files - register the dir for
# this run too, or every fresh run shows a false FAIL tex.
magpie_register_tex() {
  texbin=$(magpie_texbin)
  if [ -z "$texbin" ]; then
    return 0
  fi
  if magpie_rc_add_path "$MAGPIE_RC" "$texbin"; then
    magpie_log "TinyTeX registered in $MAGPIE_RC + this run"
  fi
}

# ---------------- GAMS ----------------

magpie_find_gams_dir() {
  # The pinned version's folder first: with several installs, never
  # hand out (or delete) a version this script did not choose.
  d="$HOME/gams/gams${GAMS_VERSION}_linux_x64_64_sfx"
  if [ -d "$d" ]; then
    printf '%s\n' "$d"
    return 0
  fi
  for d in "$HOME"/gams/gams*_linux_x64_64_sfx; do
    if [ -d "$d" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# The GAMS system folder: holds the gams binary and is where GAMS
# reads gamslice.txt. On Linux: the ~/gams sfx folder, else the folder
# of any gams found on PATH (e.g. /opt/gams). On macOS: the pkg
# framework folder.
magpie_gams_sysdir() {
  if [ "$MAGPIE_OS" != "linux" ]; then
    if [ -x "/Library/Frameworks/GAMS.framework/Resources/gams" ]; then
      printf '%s\n' "/Library/Frameworks/GAMS.framework/Resources"
      return 0
    fi
    return 1
  fi
  d=$(magpie_find_gams_dir) && {
    printf '%s\n' "$d"
    return 0
  }
  gbin=$(command -v gams 2>/dev/null) || return 1
  printf '%s\n' "$(dirname "$gbin")"
}

magpie_find_gams() {
  if command -v gams >/dev/null 2>&1; then
    command -v gams
    return 0
  fi
  if [ "$MAGPIE_OS" = "linux" ]; then
    d=$(magpie_find_gams_dir) || return 1
    if [ -x "$d/gams" ]; then
      printf '%s\n' "$d/gams"
      return 0
    fi
    return 1
  fi
  if [ -x "/Library/Frameworks/GAMS.framework/Resources/gams" ]; then
    printf '%s\n' "/Library/Frameworks/GAMS.framework/Resources/gams"
    return 0
  fi
  return 1
}

# Linux: run the pinned self-extractor inside ~/gams. The checksum is
# re-checked right before the exe runs. No gamsinst (magpie names its
# solvers itself, like the official MAgPIE Dockerfile).
magpie_gams_body_linux() {
  dl="$HOME/magpie/setup-dl-gams.exe"
  magpie_download "$GAMS_URL_LINUX_X64" "$dl" "$GAMS_SHA256_LINUX_X64" || return 1
  if [ "$(magpie_sha256 "$dl")" != "$GAMS_SHA256_LINUX_X64" ]; then
    magpie_log "checksum re-check failed before extract: $dl"
    rm -f "$dl"
    return 1
  fi
  mkdir -p "$HOME/gams" || return 1
  # Remove this version's folder only (what the extractor recreates) -
  # never another version that might still work.
  rm -rf "$HOME/gams/gams${GAMS_VERSION}_linux_x64_64_sfx"
  if ! ( cd "$HOME/gams" && chmod +x "$dl" && "$dl" >/dev/null 2>&1 ); then
    magpie_log "GAMS self-extractor failed"
    return 1
  fi
  magpie_find_gams_dir >/dev/null || return 1
  rm -f "$dl"
}

magpie_gams_body_macos() {
  magpie_install_pkg gams "$MAGPIE_PKG_URL" "$MAGPIE_PKG_SHA" || return 1
  magpie_find_gams >/dev/null
}

magpie_gams_body() {
  if [ "$MAGPIE_OS" = "linux" ]; then
    magpie_gams_body_linux
  else
    magpie_gams_body_macos
  fi
}

magpie_install_gams() {
  if magpie_find_gams >/dev/null; then
    magpie_log "GAMS: already installed"
    return 0
  fi
  if [ "$MAGPIE_OS" = "linux" ] && [ "$(uname -m)" != "x86_64" ]; then
    magpie_fail "GAMS download supports x86_64 (WSL) only - tell the TA"
  fi
  if [ "$MAGPIE_OS" != "linux" ]; then
    case $(uname -m) in
      arm64) MAGPIE_PKG_URL=$GAMS_URL_DARWIN_ARM64; MAGPIE_PKG_SHA=$GAMS_SHA256_DARWIN_ARM64 ;;
      *) MAGPIE_PKG_URL=$GAMS_URL_DARWIN_X64; MAGPIE_PKG_SHA=$GAMS_SHA256_DARWIN_X64 ;;
    esac
  fi
  magpie_say_progress "GAMS $GAMS_VERSION" "about 3-10 min (~500-670 MB download)"
  if ! magpie_retry 3 magpie_gams_body; then
    magpie_step_failed "GAMS install"
  fi
  magpie_say "OK: GAMS $GAMS_VERSION installed"
  magpie_report "setup: gams $GAMS_VERSION installed"
}

magpie_register_gams() {
  if [ "$MAGPIE_OS" = "linux" ]; then
    dir=$(magpie_find_gams_dir) || return 0
    if magpie_rc_add_path "$MAGPIE_RC" "$dir"; then
      magpie_log "GAMS registered in $MAGPIE_RC + this run"
    fi
    return 0
  fi
  if ! command -v gams >/dev/null 2>&1 \
    && [ -d "/Library/Frameworks/GAMS.framework/Resources" ] \
    && magpie_rc_add_path "$MAGPIE_RC" "/Library/Frameworks/GAMS.framework/Resources"; then
    magpie_log "GAMS registered in $MAGPIE_RC"
  fi
}

# ---------------- licence ----------------

# Where GAMS reads gamslice.txt (no env var needed):
# Linux: the GAMS system folder. macOS: first user data dir - the pkg
# folder is root-owned, mode 600 impossible there.
magpie_licence_dir() {
  if [ "$MAGPIE_OS" = "darwin" ]; then
    printf '%s\n' "$HOME/Library/Application Support/GAMS"
    return 0
  fi
  magpie_gams_sysdir
}

# True when the teacher pasted real licence text into this script
# (silent - safe to call from the checks). A blank heredoc counts as
# NOT embedded: deleting the placeholder line without pasting anything
# must not write an empty licence file.
magpie_licence_embedded() {
  marker="__PASTE_CONTENTS_OF_gamslice.txt_HERE__"
  body=$(magpie_licence_text) || return 1
  case $body in
    *"$marker"*) return 1 ;;
  esac
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]
}

# Warn once per run (setup_path checks early, install_licence later;
# the duplicate warning would hit the feed twice).
magpie_licence_available() {
  if [ -n "${MAGPIE_LIC_MISSING+x}" ]; then
    return "$MAGPIE_LIC_MISSING"
  fi
  if magpie_licence_embedded; then
    MAGPIE_LIC_MISSING=0
    return 0
  fi
  MAGPIE_LIC_MISSING=1
  magpie_say "WARNING: the course licence was not embedded in this script."
  magpie_say "Tell the TA - they will paste it into the script."
  magpie_report "setup: WARNING gamslice not embedded"
  return 1
}

magpie_install_licence() {
  dir=$(magpie_licence_dir) || dir=""
  if [ -z "$dir" ]; then
    magpie_say "GAMS folder is missing - the licence needs a rerun of this file."
    magpie_report "setup: WARNING licence not written, no gams folder"
    return 1
  fi
  target="$dir/gamslice.txt"
  # No embedded licence: never touch what is there - the demo slice
  # that the GAMS installer ships stays as it is.
  magpie_licence_available || return 1
  tmp=$(mktemp) || return 1
  magpie_licence_text > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    magpie_log "course licence: already in place"
    return 0
  fi
  # A missing dir is created below; only an EXISTING folder that
  # refuses writes is a dead end (e.g. a root-owned /opt GAMS).
  if [ -e "$dir" ] && [ ! -w "$dir" ]; then
    rm -f "$tmp"
    magpie_say "GAMS folder $dir is not writable - the licence needs a rerun of this file."
    magpie_report "setup: WARNING licence dir not writable"
    return 1
  fi
  mkdir -p "$dir"
  if [ "$MAGPIE_OS" = "darwin" ]; then
    chmod 700 "$dir"
  fi
  if [ -f "$target" ]; then
    # A DIFFERENT slice sits there - usually the demo licence the GAMS
    # installer ships. Existence alone must never skip the course
    # licence (that kept the 2026-11 machine on the demo forever); the
    # course slice replaces it, the old copy survives as .bak.
    cp "$target" "$target.bak" 2>/dev/null || true
    magpie_log "replacing non-course gamslice.txt (old copy kept as $target.bak)"
    magpie_report "setup: replaced non-course gamslice.txt"
  fi
  mv "$tmp" "$target"
  chmod 600 "$target"
  magpie_log "course licence written to $target"
}

# ---------------- nono profile ----------------

magpie_nono_pack_version() {
  sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' \
    "$HOME/.config/nono/packages/nolabs-ai/opencode/package.json" 2>/dev/null \
    | head -n 1
}

# Pull the pinned pack version. The installed package.json must then
# report exactly the pin.
magpie_nono_pull() {
  ref="nolabs-ai/opencode@$NONO_PACK_VERSION"
  if [ -n "${MAGPIE_PACK_FORCE:-}" ]; then
    nono pull --force "$ref" || return 1
  else
    nono pull "$ref" || return 1
  fi
  if [ "$(magpie_nono_pack_version)" != "$NONO_PACK_VERSION" ]; then
    magpie_log "nono pack wrong version after pull: got $(magpie_nono_pack_version), want $NONO_PACK_VERSION"
    return 1
  fi
  return 0
}

# The pack defines the sandbox, so the version is pinned like the
# binaries: same pull on every machine, no silent registry drift.
magpie_pull_nono_profile() {
  marker="$HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
  MAGPIE_PACK_FORCE=""
  if [ -f "$marker" ]; then
    if [ "$(magpie_nono_pack_version)" = "$NONO_PACK_VERSION" ]; then
      magpie_log "nono profile opencode: already pulled"
      return 0
    fi
    magpie_log "nono pack version drift: got $(magpie_nono_pack_version), want $NONO_PACK_VERSION"
    MAGPIE_PACK_FORCE=1
  fi
  magpie_say_progress "course sandbox settings" "about 1 min"
  if ! magpie_retry 3 magpie_nono_pull; then
    magpie_step_failed "nono profile pull"
  fi
  # Pin keeps the pack out of `nono update`: the sandbox policy stays
  # exactly as pinned until this script raises the pin. Best effort.
  nono pin nolabs-ai/opencode >/dev/null 2>&1 \
    || magpie_log "nono pack pin failed - updates not blocked, tell the TA"
  magpie_log "nono profile opencode pulled ($NONO_PACK_VERSION)"
  magpie_report "setup: nono profile pulled"
}

# Course profile on top of the pinned opencode pack: read-list for
# GAMS, R, gfortran, TinyTeX and the licence folder; write-list for the
# madrat mainfolder (cache for any madrat reads) and the renv cache
# folder (run-folder renv restores through it).
# Optional read folders go in only when they exist: the validator
# rejects a policy path missing on disk, and several are optional -
# ~/.TinyTeX stays missing when apt provided tex, the macOS licence
# folder when no licence is embedded, the macOS pkg framework/gfortran
# folders when a tool was installed another way. The two cache folders
# are created by magpie_register_caches before this step, so they stay
# literal lines (the write list must not depend on folder luck).
# Collect the read list: keep a candidate only when it exists and no
# earlier entry already covers it (exact path, or an earlier entry is
# its parent - e.g. R.home() covers the base library below it).
magpie_add_read_dir() {
  d=$1
  if [ -z "$d" ] || [ ! -d "$d" ]; then
    return 0
  fi
  # shellcheck disable=SC2154  # MAGPIE_READ_DIRS is built by the caller.
  oldIFS=$IFS
  IFS='
'
  for e in $MAGPIE_READ_DIRS; do
    if [ "$d" = "$e" ] || [ "${d#"$e"/}" != "$d" ]; then
      IFS=$oldIFS
      return 0
    fi
  done
  IFS=$oldIFS
  MAGPIE_READ_DIRS="$MAGPIE_READ_DIRS$d
"
}

magpie_build_nono_profile() {
  dir="$HOME/.config/nono/profiles"
  f="$dir/magpie-profile.json"
  mkdir -p "$dir" || return 1
  tmp=$(mktemp) || return 1
  MAGPIE_READ_DIRS=""
  if [ "$MAGPIE_OS" = "darwin" ]; then
    magpie_add_read_dir "/Library/Frameworks/R.framework"
    magpie_add_read_dir "$MAGPIE_GFORTRAN_DIR_NEW"
    magpie_add_read_dir "$MAGPIE_GFORTRAN_DIR"
    magpie_add_read_dir "$HOME/Library/TinyTeX"
    magpie_add_read_dir "$HOME/.TinyTeX"
    magpie_add_read_dir "$HOME/Library/Application Support/GAMS"
    for d in $MAGPIE_TOOLCHAIN_DIRS_DARWIN; do
      magpie_add_read_dir "$d"
    done
  else
    # A GAMS found outside ~/gams (any PATH install) must be readable
    # in the sandbox too.
    gd=$(magpie_gams_sysdir 2>/dev/null) || gd=""
    case $gd in
      ""|"$HOME/gams"|"$HOME/gams"/*) gd="" ;;
    esac
    magpie_add_read_dir "$HOME/gams"
    magpie_add_read_dir "$gd"
    magpie_add_read_dir "$HOME/.TinyTeX"
    # Source package builds (start.R installs ~300 packages, dozens
    # with C/Fortran code): the /usr/bin gcc driver spawns cc1/cc1plus
    # and collect2 from trees nono's system groups do not cover, and
    # every compile reads /usr/include. Without these the renv stack
    # dies on "cc1: posix_spawn: Permission denied".
    for d in $MAGPIE_TOOLCHAIN_DIRS; do
      magpie_add_read_dir "$d"
    done
    # start.R's requirements check probes system packages via
    # dpkg-query; without the status DB it silently reports every
    # system dependency as missing.
    for d in $MAGPIE_DPKG_DIRS; do
      magpie_add_read_dir "$d"
    done
  fi
  # R must be VISIBLE in the sandbox, not just executable: apt R keeps
  # Renviron and the base library under its home (/usr/lib/R), the
  # course stack under a site-library - nono's default groups cover
  # neither, and R died inside the sandbox with "cannot find system
  # Renviron". Query home + library paths unsandboxed; skip silently
  # when no R is present.
  if command -v Rscript >/dev/null 2>&1; then
    oldIFS=$IFS
    IFS='
'
    for rd in $(Rscript -e 'cat(R.home()); cat("\n"); cat(.libPaths(), sep = "\n")' \
      2>/dev/null); do
      magpie_add_read_dir "$rd"
    done
    IFS=$oldIFS
    # Debian/Ubuntu: the R home's etc/ is a REAL folder holding
    # SYMLINKED files (Renviron, ldpaths, repositories -> /etc/R).
    # The grant on the R home does not follow links out of its tree,
    # so R dies inside the sandbox without its Renviron (no EDITOR ->
    # utils .onLoad error). R itself resolves the link target folder
    # (readLink needs no read rights on the target); on macOS and
    # non-symlink builds it resolves inside the R home and dedupes.
    rd_etc=$(Rscript -e 'p <- file.path(R.home("etc"), "Renviron"); if (file.exists(p)) cat(dirname(normalizePath(p)))' \
      2>/dev/null)
    magpie_add_read_dir "$rd_etc"
  fi
  # R user dirs (tools::R_user_dir): packages cache into them AT LOAD
  # TIME - readable AND writable, created by magpie_register_caches
  # before this step runs. Newline-IFS loop (paths may hold spaces, no
  # process substitution): the same pattern as the read list below.
  write_extra=""
  oldIFS=$IFS
  IFS='
'
  for d in $(magpie_r_user_dirs); do
    magpie_add_read_dir "$d"
    write_extra="$write_extra      \"$d\",
"
  done
  IFS=$oldIFS
  read_extra=""
  # The GAMS.framework entry stays literal on macOS (not existence-
  # gated): magpie_install_gams only reports success with that folder
  # present, and the offline harness cannot fake /Library.
  if [ "$MAGPIE_OS" = "darwin" ]; then
    read_extra="      \"/Library/Frameworks/GAMS.framework\",
"
  fi
  oldIFS=$IFS
  IFS='
'
  for d in $MAGPIE_READ_DIRS; do
    read_extra="$read_extra      \"$d\",
"
  done
  IFS=$oldIFS
  # The sandboxed gate child re-executes this very file (--check-only)
  # and reads the course handle file; $HOME itself is not readable in
  # the sandbox: list both files readable. The script path is the
  # (relocated, native) MAGPIE_SELF; a moved script regenerates the
  # profile through the marker check.
  rf=""
  for mf in "${MAGPIE_SELF:-}" "$MAGPIE_HANDLE_FILE"; do
    if [ -n "$mf" ] && [ -f "$mf" ]; then
      rf="$rf{ \"path\": \"$mf\" }, "
    fi
  done
  read_file_entry=""
  if [ -n "$rf" ]; then
    rf=${rf%", "}
    read_file_entry="    \"read_file\": [ $rf ],
"
  fi
  cat > "$tmp" <<EOF
{
  "meta": {
    "name": "magpie-profile",
    "description": "MAgPIE course: opencode + GAMS + R + TinyTeX (setup v$MAGPIE_PROFILE_SCHEMA)"
  },
  "extends": ["nolabs-ai/opencode"],
  "filesystem": {
    "read": [
$read_extra      "$MADRAT_MAINFOLDER",
      "$RENV_PATHS_CACHE"
    ],
$read_file_entry    "write": [
$write_extra      "$MADRAT_MAINFOLDER",
      "$RENV_PATHS_CACHE"
    ]
  }
}
EOF
  if ! verr=$(nono profile validate "$tmp" 2>&1); then
    # nono's real complaint belongs in the log: a bare "failed
    # validation" leaves whoever reads the feed guessing (that is how
    # the 2026-11 course run went blind). Log all of it, banner
    # included - a cap cut off the real error once. The rejected
    # candidate rides along on ONE line: the failure post carries the
    # last 25 log lines, and a 60-line JSON dump would push the actual
    # diagnostics out of that tail.
    magpie_log "generated nono profile failed validation: $verr"
    magpie_log "rejected candidate: $(tr '\n' ' ' < "$tmp" 2>/dev/null | tr -s ' ')"
    rm -f "$tmp"
    return 1
  fi
  if [ -f "$f" ]; then
    if cmp -s "$tmp" "$f"; then
      magpie_log "nono profile magpie-profile: already in place"
    elif grep -q '"description".*"MAgPIE course' "$f" 2>/dev/null; then
      # Carries our marker: written by this script (an older schema
      # version) - regenerate, keep the old copy as .bak. A hand-made
      # profile keeps no marker and is left alone.
      cp "$f" "$f.bak" 2>/dev/null || true
      mv "$tmp" "$f"
      magpie_log "nono profile regenerated (stale generated copy kept as $f.bak)"
      return 0
    else
      magpie_log "nono profile $f was changed - keeping it (delete it to regenerate)"
    fi
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$f"
  magpie_log "created nono profile: $f"
}

magpie_step_magpie_profile() {
  if ! magpie_retry 3 magpie_build_nono_profile; then
    magpie_step_failed "magpie-profile build"
  fi
  magpie_log "nono profile magpie-profile in place"
}

# ---------------- magpie clone ----------------

magpie_clone_body() {
  repo="$HOME/magpie"
  git -C "$repo" init -q || return 1
  git -C "$repo" remote get-url origin >/dev/null 2>&1 \
    || git -C "$repo" remote add origin "$MAGPIE_MAGPIE_URL" || return 1
  branch=$(GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
    git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '/^ref:/ {print $2; exit}' | sed 's@^refs/heads/@@')
  if [ -z "$branch" ]; then
    magpie_log "could not read default branch from origin"
    return 1
  fi
  GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
    git -C "$repo" fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch" \
    || return 1
  git -C "$repo" checkout -q -B "$branch" "origin/$branch" || return 1
}

# A finished clone resolves HEAD. An interrupted fetch leaves .git
# without a checkout - existence of .git alone is not enough. The .git
# test first: without it, git would walk up into a parent repository.
magpie_clone_ok() {
  [ -e "$HOME/magpie/.git" ] && \
    git -C "$HOME/magpie" rev-parse HEAD >/dev/null 2>&1
}

# Normalise a git URL for comparison: strip scheme, user@, the
# scp-style colon, the trailing .git and any trailing slash.
magpie_url_key() {
  u=$1
  # A trailing slash is spelling, not another path.
  while [ "${u%/}" != "$u" ]; do
    u=${u%/}
  done
  u=${u%.git}
  case $u in
    *://*) u=${u#*://}; u=${u#*@} ;;
  esac
  case $u in
    *@*) u=${u#*@} ;;
  esac
  # scp-style host:path (no slash in the host part) -> host/path
  case $u in
    *:*)
      case ${u%%:*} in
        */*) ;;
        *) u="${u%%:*}/${u#*:}" ;;
      esac
      ;;
  esac
  printf '%s\n' "$u"
}

# True when an existing origin can serve as the magpie source: the
# configured URL (normalised - ssh vs https and .git differences are
# cosmetic), the official org/repo, or the same repo name under any
# owner (a fork the student pushed).
magpie_clone_url_ok() {
  want=$(magpie_url_key "$MAGPIE_MAGPIE_URL")
  have=$(magpie_url_key "$1")
  [ "$have" = "$want" ] && return 0
  case $have in
    magpiemodel/magpie|*/magpiemodel/magpie) return 0 ;;
  esac
  [ "${have##*/}" = "${want##*/}" ] && [ -n "${have##*/}" ] && return 0
  return 1
}

magpie_clone_magpie() {
  if [ -d "$HOME/magpie/.git" ]; then
    cur=$(git -C "$HOME/magpie" remote get-url origin 2>/dev/null)
    if [ -n "$cur" ] && ! magpie_clone_url_ok "$cur"; then
      magpie_fail "magpie folder exists but is not a magpie clone - move it away or delete it"
    fi
    if [ -n "$cur" ] && [ "$cur" != "$MAGPIE_MAGPIE_URL" ]; then
      magpie_log "magpie: origin is $cur (not the configured URL) - using the existing clone"
    fi
    if magpie_clone_ok; then
      magpie_log "magpie: already cloned"
      return 0
    fi
    magpie_log "magpie: interrupted clone found - healing"
  fi
  # shellcheck disable=SC2045  # ls -A: own-file allowlist check includes dotfiles.
  for entry in $(ls -A "$HOME/magpie" 2>/dev/null); do
    case $entry in
      # setup-help.txt + setup-help-profile.json: copies distributed
      # before the AI help block was removed may have left them there
      # (the .json held a rejected profile - written exactly by the
      # runs that never reached the clone). A stray file must never
      # block the clone of an otherwise clean folder.
      .git|setup-log.txt|setup-help.txt|setup-help-profile.json| \
      .setup-finished|.setup.lock| \
      .keepalive.pid|.setup-fullrun-ok|opencode-dl.tgz|opencode-extract| \
      nono-dl.tar.gz|nono-extract|setup-dl-*) ;;
      *)
        magpie_fail "magpie folder exists but is not a magpie clone - move it away or delete it"
        ;;
    esac
  done
  magpie_say_progress "magpie" "about 2-5 min"
  if ! magpie_retry 3 magpie_clone_body; then
    magpie_step_failed "magpie clone"
  fi
  magpie_say "OK: magpie downloaded (~/magpie)"
}

# ---------------- renv library ----------------

# The project library load test - shared by the checks and this step.
magpie_renv_lib_ok() {
  ( cd "$HOME/magpie" \
    && Rscript -e 'suppressMessages(library(lucode2)); suppressMessages(library(gms))' \
  ) >/dev/null 2>&1
}

# The shipped renv/activate.R never asks anything - it only bootstraps
# the renv package itself, so it is safe to run non-interactively.
magpie_renv_restore_body() {
  ( cd "$HOME/magpie" || exit 1
    if ! Rscript -e 'quit(status = if (requireNamespace("renv", quietly = TRUE)) 0 else 1)' \
      2>/dev/null; then
      Rscript -e 'source("renv/activate.R")' || exit 1
    fi
    Rscript -e 'renv::restore(prompt = FALSE, restart = FALSE)' || exit 1
  ) || return 1
  magpie_renv_lib_ok
}

# Fill the renv library the clone ships, so checks and runs use it.
magpie_step_renv_restore() {
  if [ ! -f "$HOME/magpie/renv.lock" ]; then
    magpie_log "renv restore: no renv.lock - skipped"
    return 0
  fi
  if magpie_renv_lib_ok; then
    magpie_log "renv library: already populated"
    return 0
  fi
  magpie_say_progress "R packages" "about 5-15 min, just wait"
  if ! magpie_retry 3 magpie_renv_restore_body; then
    magpie_step_failed "renv restore"
  fi
  magpie_say "OK: R packages installed"
  magpie_report "setup: renv restored"
}

# ---------------- checks (unsandboxed + sandbox child) ----------------

# One accumulated result line: "PASS gams ..." etc.
magpie_check_line() {
  MAGPIE_CHECK_RESULTS="$MAGPIE_CHECK_RESULTS
$1 $2"
}

magpie_run_checks() {
  MAGPIE_CHECK_RESULTS=""

  if gbin=$(magpie_find_gams); then
    # GAMS writes into its work folder: probe only inside a scratch
    # dir (removed afterwards), never where this script happens to run.
    gtmp=$(mktemp -d 2>/dev/null) || gtmp=""
    gout=""
    if [ -n "$gtmp" ]; then
      # shellcheck disable=SC2015  # any failure must still yield output, not abort.
      gout=$( cd "$gtmp" && "$gbin" 2>&1 || true )
      rm -rf "$gtmp"
    fi
    # The course-licence PASS reads the banner whenever the licensee
    # constant is set - embedded or not: a banner that carries the
    # course licensee IS the course licence, however it got installed
    # (rerun with a filled script, TA setup, magpie-opencode.sh).
    # Without an embedded slice the banner must additionally show no
    # demo/expired wording, so a demo can never pose as the course
    # licence. lic_named (constant + pasted licence) keeps the strict
    # plan where the name outranks demo wording.
    lic_named=""
    if [ -n "$MAGPIE_COURSE_LICENSEE" ] && magpie_licence_embedded; then
      lic_named=1
    fi
    lic_banner=""
    if [ -n "$MAGPIE_COURSE_LICENSEE" ] \
      && printf '%s\n' "$gout" | grep -qiF "$MAGPIE_COURSE_LICENSEE"; then
      lic_banner=1
    fi
    if [ -z "$gtmp" ]; then
      magpie_check_line FAIL "gams licence check needs a temp folder - free space in /tmp and rerun this file"
    elif [ -n "$lic_banner" ] \
      && { [ -n "$lic_named" ] \
        || ! printf '%s\n' "$gout" | grep -qiE "demo|expired"; }; then
      magpie_check_line PASS "gams (course licence found)"
    elif printf '%s\n' "$gout" | grep -qiE "demo|expired"; then
      magpie_check_line FAIL "gams runs only with the free demo licence - the course licence file is missing - rerun this file"
    elif [ -n "$lic_named" ]; then
      magpie_check_line FAIL "gams licence is not the course licence (no $MAGPIE_COURSE_LICENSEE) - tell the TA"
    elif printf '%s\n' "$gout" | grep -qiE "license is valid|licensee"; then
      magpie_check_line PASS "gams (license found)"
    else
      magpie_check_line FAIL "gams found but its licence file is missing - rerun this file"
    fi
  else
    magpie_check_line FAIL "gams not installed - rerun this file"
  fi

  if command -v git >/dev/null 2>&1; then
    v=$(git --version | awk '{print $3}')
    major=${v%%.*}
    rest=${v#*.}
    minor=${rest%%.*}
    if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 23 ]; }; then
      magpie_check_line PASS "git $v"
    else
      magpie_check_line FAIL "git $v older than 2.23 - tell the course team"
    fi
  else
    magpie_check_line FAIL "git not found - rerun this file"
  fi

  if command -v Rscript >/dev/null 2>&1; then
    # --vanilla: a pure version test must not depend on the project
    # .Rprofile (gate child runs from ~/magpie, where renv's
    # bootstrap has no business deciding whether R "exists").
    if Rscript --vanilla -e 'quit(status = if (getRversion() >= "4.3") 0 else 1)' 2>/dev/null; then
      magpie_check_line PASS "R $(Rscript --vanilla -e 'cat(as.character(getRversion()))' 2>/dev/null)"
    else
      magpie_check_line FAIL "R older than 4.3 - tell the course team"
    fi
  else
    magpie_check_line FAIL "Rscript not found - rerun this file"
  fi

  if command -v pandoc >/dev/null 2>&1; then
    magpie_check_line PASS "pandoc $(pandoc --version | head -n 1 | awk '{print $2}')"
  else
    magpie_check_line FAIL "pandoc not found - rerun this file"
  fi

  if command -v tex >/dev/null 2>&1; then
    magpie_check_line PASS "tex (TinyTeX)"
  else
    magpie_check_line FAIL "tex not found - rerun this file"
  fi

  # R libraries. With a renv.lock the pinned library has to load;
  # without one (every course machine: start.R snapshots into the RUN
  # folder, never into the repo root) the libraries only exist once the
  # full run installed them - so the load test runs from the full-run
  # marker onwards. Parent only: a Landlock denial on this probe would
  # block the gate with a message the student cannot act on, and the
  # sandboxed full run that follows tests the library far better.
  fullrel=$(magpie_fullrel)
  if [ -f "$HOME/magpie/renv.lock" ]; then
    if magpie_renv_lib_ok; then
      magpie_check_line PASS "renv R library (lucode2, gms load)"
    else
      magpie_check_line FAIL "renv R library incomplete - in ~/magpie run: Rscript -e 'renv::restore()'"
    fi
  elif [ -n "$fullrel" ] && [ -z "${MAGPIE_CHECK_ONLY:-}" ]; then
    if magpie_renv_lib_ok; then
      magpie_check_line PASS "R libraries (lucode2, gms load)"
    else
      magpie_check_line FAIL "R libraries incomplete - in ~/magpie run: Rscript start.R once"
    fi
  fi

  # Full default run: marker + artifacts only - cheap and read-only, it
  # also runs inside the sandbox gate child. No marker is "not yet", not
  # a skipped check: the step at the end of this setup runs it and the
  # verdict block reports the outcome, so nothing is printed here.
  if [ "${MAGPIE_FULL_RUN:-1}" = "0" ]; then
    magpie_check_line SKIP "full run (skipped via MAGPIE_FULL_RUN=0)"
  elif [ -n "$fullrel" ]; then
    if magpie_full_run_complete "$HOME/magpie/$fullrel"; then
      magpie_check_line PASS "full run ($fullrel)"
    else
      magpie_check_line FAIL "full run artifacts missing - rerun this file"
    fi
  fi

  magpie_say ""
  magpie_say "system: $(uname -s) $(uname -m) | code name: $MAGPIE_HANDLE"
  printf '%s\n' "${MAGPIE_CHECK_RESULTS#"
"}" >&4

  if [ -n "${MAGPIE_CHECK_ONLY:-}" ]; then
    magpie_report "sandbox check result$MAGPIE_CHECK_RESULTS"
  else
    magpie_report "check result$MAGPIE_CHECK_RESULTS"
  fi

  if printf '%s\n' "$MAGPIE_CHECK_RESULTS" | grep -q '^FAIL'; then
    return 1
  fi
  return 0
}

# Final gate: the same checks again, inside the course sandbox.
# PATH and the cache dirs are passed explicitly - bash does not source
# rc files here.
magpie_sandbox_gate() {
  if [ -z "${MAGPIE_SELF:-}" ]; then
    magpie_fail "sandbox gate: cannot locate this file - run it as a file, not pasted"
  fi
  texbin=$(magpie_texbin)
  magpie_say "Final check inside the course sandbox..."
  # The child's stdout+stderr are appended to the log - nothing of the
  # child (nor of nono itself) reaches the screen: the parent has
  # already printed the check block, so a tee would duplicate it.
  # --allow-cwd: the course runs from ~/magpie (this subshell's cwd) -
  # without the flag nono interactively prompts "Share cwd read+write?"
  # before applying the sandbox.
  ( cd "$HOME/magpie" && nono run --profile magpie-profile --allow-cwd -- \
    env MAGPIE_CHECK_ONLY=1 "PATH=${texbin:+$texbin:}$PATH" \
    "MADRAT_MAINFOLDER=$MADRAT_MAINFOLDER" "RENV_PATHS_CACHE=$RENV_PATHS_CACHE" \
    bash "$MAGPIE_SELF" --check-only ) \
    >> "$HOME/magpie/setup-log.txt" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    magpie_say "OK: sandbox check passed"
  fi
  return "$rc"
}

# ---------------- full default run (sandboxed) ----------------

# Solve + default postprocessing done? The run-folder submit.R stops
# without fulldata.gdx, and report.rds/report.mif are written by the
# last default output script (rds_report). full.lst = GAMS listing.
magpie_full_run_complete() {
  [ -f "$1/fulldata.gdx" ] && [ -f "$1/full.lst" ] \
    && [ -f "$1/report.rds" ] && [ -f "$1/report.mif" ]
}

# Marker content (output/<run folder>) or "" - one place, three users:
# the checks, the verdict block and the log's final line.
magpie_fullrel() {
  if [ -f "$HOME/magpie/.setup-fullrun-ok" ]; then
    cat "$HOME/magpie/.setup-fullrun-ok" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Newest complete run folder under output/ ("" if none). Folder names
# are default_<timestamp> (cfg$results_folder), so lexical = newest last.
magpie_latest_full_run() {
  out="$HOME/magpie/output"
  if [ ! -d "$out" ]; then
    return 0
  fi
  # Run folder names are fixed pattern, no spaces (see grep).
  # shellcheck disable=SC2010,SC2045,SC2046
  for name in $(ls -1 "$out" 2>/dev/null | grep -E \
    '^default_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}\.[0-9]{2}\.[0-9]{2}$' | sort -r); do
    if magpie_full_run_complete "$out/$name"; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 0
}

# $1: PATH for the sandboxed child (tex + GAMS dirs included).
magpie_full_run_body() {
  # The answers start.R gets on stdin depend on its flow, which
  # depends on renv.lock: WITHOUT a lockfile (every first full run)
  # the prompt is the requirements check "Try to fix automatically?
  # (Y/n)" - answering n there skips installing the whole dependency
  # stack (that is how the 2026-11 course runs halted on "no package
  # called 'lucode2'"). WITH a lockfile the prompts are "Update now?"
  # and fixDeps - both answered n so the restored versions stay.
  # Not </dev/null - EOF makes gms::getLine return character(0),
  # which crashes the &&. --allow-cwd is mandatory here: without it
  # the piped answers would hit nono's cwd prompt instead of start.R.
  if [ -f "$HOME/magpie/renv.lock" ]; then
    MAGPIE_FULL_RUN_ANSWERS=$(printf 'n\nn')
  else
    MAGPIE_FULL_RUN_ANSWERS=$(printf 'y')
  fi
  if [ "$MAGPIE_OS" = "darwin" ]; then
    # shellcheck disable=SC2016  # $HOME expands in the sandbox child, not here.
    printf '%s\n' "$MAGPIE_FULL_RUN_ANSWERS" | ( cd "$HOME/magpie" && caffeinate -is nono run --profile magpie-profile --allow-cwd -- \
      env "MADRAT_MAINFOLDER=$MADRAT_MAINFOLDER" "RENV_PATHS_CACHE=$RENV_PATHS_CACHE" \
      "PATH=$1" \
      bash -c 'cd "$HOME/magpie" && Rscript start.R runscripts=default.R submit=direct' )
  else
    # shellcheck disable=SC2016  # $HOME expands in the sandbox child, not here.
    printf '%s\n' "$MAGPIE_FULL_RUN_ANSWERS" | ( cd "$HOME/magpie" && nono run --profile magpie-profile --allow-cwd -- \
      env "MADRAT_MAINFOLDER=$MADRAT_MAINFOLDER" "RENV_PATHS_CACHE=$RENV_PATHS_CACHE" \
      "PATH=$1" \
      bash -c 'cd "$HOME/magpie" && Rscript start.R runscripts=default.R submit=direct' )
  fi
}

# One full default run inside the course sandbox. ONE attempt - start.R
# swallows run errors, so a NEW complete run folder decides, not the
# exit code. Any failure goes straight to the failure verdict.
magpie_step_full_run() {
  marker="$HOME/magpie/.setup-fullrun-ok"
  if [ "${MAGPIE_FULL_RUN:-1}" = "0" ]; then
    magpie_say "Full run skipped (MAGPIE_FULL_RUN=0) - run it yourself: cd ~/magpie, then Rscript start.R"
    magpie_report "setup: full run skipped (MAGPIE_FULL_RUN=0)"
    return 0
  fi
  fullrel=$(magpie_fullrel)
  if [ -n "$fullrel" ] && magpie_full_run_complete "$HOME/magpie/$fullrel"; then
    magpie_log "full run: marker verified ($fullrel)"
    return 0
  fi
  runpath=$PATH
  texbin=$(magpie_texbin)
  if [ -n "$texbin" ]; then
    runpath="$texbin:$runpath"
  fi
  if [ "$MAGPIE_OS" = "linux" ]; then
    gamsdir=$(magpie_gams_sysdir) && runpath="$gamsdir:$runpath"
  elif [ -d "/Library/Frameworks/GAMS.framework/Resources" ]; then
    runpath="/Library/Frameworks/GAMS.framework/Resources:$runpath"
  fi
  magpie_say "[$(magpie_now)] - full magpie run, about 40 min, keep the laptop plugged in and awake"
  magpie_report "setup: full run start"
  before=$(magpie_latest_full_run)
  if ! magpie_full_run_body "$runpath"; then
    magpie_fail "full magpie run (check the run folder under ~/magpie)"
  fi
  after=$(magpie_latest_full_run)
  if [ -z "$after" ] || [ "$after" = "$before" ]; then
    magpie_fail "full magpie run (check the run folder under ~/magpie)"
  fi
  printf 'output/%s\n' "$after" > "$marker"
  magpie_log "full run: wrote marker output/$after"
  magpie_say "OK: full magpie run finished (output/$after)"
  magpie_report "setup: full run finished"
}

# An older copy of this file wrote an "AI help" block next to the log
# (setup-help.txt, and setup-help-profile.json for a rejected profile).
# Nothing writes them any more, and a stale FAIL block on a machine that
# just passed every check is pure confusion - so the green path drops
# them. Never on a failing path: whoever is mid-troubleshooting may
# still be reading exactly that file.
magpie_drop_stale_help() {
  rm -f "$HOME/magpie/setup-help.txt" "$HOME/magpie/setup-help-profile.json"
}

# The very last thing on screen. The old NEXT STEPS block is gone - the
# course page has it, and a run that worked should end in a verdict a
# student recognises at a glance instead of four instruction lines. =
# bars, never # bars: nothing else in the output uses them, so the
# verdict stays the only banner on a successful run.
magpie_print_verdict() {
  fullrel=$(magpie_fullrel)
  runline="$fullrel"
  if [ -z "$runline" ]; then
    if [ "${MAGPIE_FULL_RUN:-1}" = "0" ]; then
      runline="skipped (MAGPIE_FULL_RUN=0)"
    else
      runline="see above"
    fi
  fi
  magpie_say ""
  magpie_say "============================================================"
  magpie_say " SETUP COMPLETE - MAgPIE is installed, checked and working"
  magpie_say "   checks: no FAIL   sandbox: ok   default run: $runline"
  magpie_say "============================================================"
}

# ---------------- main ----------------

# All state lives under ~/magpie (same filenames as magpie-opencode.sh).
# .setup-finished belongs to magpie-opencode.sh - never written here.
magpie_setup_path() {
  if [ "$(id -u)" = "0" ]; then
    magpie_fail "do not run as root - run: bash setup-magpie.sh"
  fi
  magpie_require_pins
  magpie_check_disk
  # Placeholder check runs early: the warning reaches the feed before
  # the long installs, not at the end.
  magpie_licence_available || true
  magpie_take_lock

  magpie_step_os_base
  magpie_install_opencode
  magpie_install_nono
  if ! magpie_write_opencode_config; then
    magpie_step_failed "opencode config"
  fi
  magpie_register_hu_key
  if ! magpie_register_caches; then
    magpie_step_failed "cache folders"
  fi

  magpie_step_course_tools
  magpie_step_tinytex

  magpie_install_gams
  magpie_register_gams
  magpie_install_licence || true
  # Last step that may need sudo is done: stop refreshing and cool the
  # cached credential already here (the gate + full run follow).
  magpie_stop_keepalive

  magpie_pull_nono_profile
  magpie_step_magpie_profile
  magpie_clone_magpie
  magpie_step_renv_restore

  # Reproducible-failure model: any check FAIL ends the run with the
  # failure verdict - the old "continue after FAIL" is gone.
  if ! magpie_run_checks; then
    magpie_fail "checks" "$MAGPIE_CHECK_RESULTS"
  fi

  # No warm sudo credential may exist while a sandboxed child runs
  # (gate + full run).
  magpie_stop_keepalive
  if ! magpie_sandbox_gate; then
    magpie_step_failed "sandbox gate"
  fi

  magpie_step_full_run
  magpie_drop_stale_help
  magpie_print_verdict
  magpie_report "setup: run finished"
  # The log's last line is the verdict too: `tail -n 1 setup-log.txt`
  # has to settle "did it work?" without reading the whole file.
  fullrel=$(magpie_fullrel)
  if [ -n "$fullrel" ]; then
    magpie_log "SETUP COMPLETE - all checks passed, full run $fullrel"
  else
    magpie_log "SETUP COMPLETE - all checks passed, full run skipped (MAGPIE_FULL_RUN=0)"
  fi
  exit 0
}

magpie_main() {
  case ${1:-} in
    --check-only) MAGPIE_CHECK_ONLY=1 ;;
  esac
  case "$(uname)" in
    Darwin)
      MAGPIE_OS=darwin
      MAGPIE_RC="$HOME/.zshrc"
      ;;
    Linux)
      MAGPIE_OS=linux
      MAGPIE_RC="$HOME/.bashrc"
      ;;
    *)
      MAGPIE_OS=unknown
      MAGPIE_RC="$HOME/.profile"
      magpie_fail "unsupported OS: $(uname) - this file is for macOS and WSL Ubuntu"
      ;;
  esac
  export HU_API_KEY="${HU_API_KEY:-required-but-not-used}"

  # Sandbox gate child: greet + checks only. No lock, no sudo, no tee,
  # no installs - recursion-proof. Exit code = checks result.
  if [ -n "${MAGPIE_CHECK_ONLY:-}" ]; then
    magpie_greet
    if magpie_run_checks; then
      exit 0
    fi
    exit 1
  fi

  magpie_greet
  magpie_report "setup: start"
  magpie_setup_path
}

# Resolve this file's absolute path, for the fresh-process pass 2.
magpie_entry() {
  # Feed fingerprint of this build (teacher fill-ins masked - see
  # magpie_setup_version): the agent maps hash -> build across every
  # distributed copy. Unknown hash = truncated or edited download.
  MAGPIE_SETUP_VERSION=$(magpie_setup_version "$0")
  MAGPIE_SETUP_VERSION=${MAGPIE_SETUP_VERSION:-unknown}
  if [ "${1:-}" = "--script-hash" ]; then
    # Print this build's feed hash and leave: no log, no handle, no
    # lock, no feed, no relocation. Teachers record it per build; an
    # agent reads it off any student copy, filled or not.
    if [ "$MAGPIE_SETUP_VERSION" = unknown ]; then
      exit 1
    fi
    printf '%s\n' "$MAGPIE_SETUP_VERSION"
    exit 0
  fi
  MAGPIE_SELF=""
  if [ -f "$0" ]; then
    # shellcheck disable=SC1007  # CDPATH= applies to cd only, not an assignment.
    dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
    if [ -n "$dir" ]; then
      MAGPIE_SELF="$dir/$(basename -- "$0")"
    fi
  fi
  magpie_arm_traps
  check_only="${MAGPIE_CHECK_ONLY:-}"
  case ${1:-} in
    --check-only) check_only=1 ;;
  esac
  if [ -n "$check_only" ]; then
    # Sandbox gate child: a denied write must not abort - the checks
    # report what the sandbox lets them see. No log file either.
    mkdir -p "$HOME/magpie" 2>/dev/null || true
    magpie_main ${1+"$@"}
  else
    if ! mkdir -p "$HOME/magpie" 2>/dev/null; then
      magpie_fail "cannot create ~/magpie - check disk space and folder rights"
    fi
    # Windows-drive invocation -> native copy for sandboxed steps
    # (log-only: the student never sees a 9P note).
    magpie_native_self_copy >> "$HOME/magpie/setup-log.txt" 2>&1
    magpie_main ${1+"$@"} >> "$HOME/magpie/setup-log.txt" 2>&1
  fi
}

if [ -z "${MAGPIE_SOURCED:-}" ]; then
  exec 4>&1
  magpie_entry ${1+"$@"}
fi
