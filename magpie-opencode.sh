#!/usr/bin/env bash
# MAgPIE course: essential setup + daily launcher. Standalone, safe to rerun.
# Bootstrapping: installs opencode + nono + HU config + nono profile + magpie
# clone, then opens opencode inside the nono sandbox in ~/magpie.
# Regular (bootstrapping finished): starts the sandbox directly - no sudo, no network.
# Works on macOS (Apple Silicon and Intel) and WSL Ubuntu. Baseline bash 3.2.

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

# ============================================================
# END PINNED BLOCK
# ============================================================

set -u

# Timing knobs (seconds). Defaults are the spec values.
MAGPIE_DISK_MIN_GB="${MAGPIE_DISK_MIN_GB:-4}"
MAGPIE_RETRY_SECS="${MAGPIE_RETRY_SECS:-10}"
MAGPIE_RETRY_SECS2="${MAGPIE_RETRY_SECS2:-30}"
MAGPIE_PASS_SECS="${MAGPIE_PASS_SECS:-30}"
MAGPIE_KEEPALIVE_SECS="${MAGPIE_KEEPALIVE_SECS:-60}"
MAGPIE_QUICKFAIL_SECS="${MAGPIE_QUICKFAIL_SECS:-15}"
MAGPIE_SUDO_RETRY_SECS="${MAGPIE_SUDO_RETRY_SECS:-2}"

# Clone source. Variable only so the offline test harness can point
# it at a local repository.
MAGPIE_MAGPIE_URL="${MAGPIE_MAGPIE_URL:-https://github.com/magpiemodel/magpie.git}"

# Work dir for EVERYTHING this script writes: log, lock, keep-alive
# pidfile, downloads, the finish marker. ~/magpie is reserved for the
# clone plus the repo-native artifacts the clone itself produces.
# Derived from $HOME, so the offline harness's fake HOME scopes every
# path automatically (same constant as setup-magpie.sh).
MAGPIE_SETUP_DIR="$HOME/setup-magpie"

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

# ---------------- error handling ----------------

magpie_sys_string() {
  if [ "$(uname)" = "Darwin" ]; then
    printf 'macOS %s\n' "$(sw_vers -productVersion 2>/dev/null)"
  else
    grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f 2
  fi
}

# Final verdict: one screen verdict + exit 1. This script has no feed, so
# the screen has to carry what the setup script uploads: the step, its
# hint, the system string and the log's last line (the rest stays in the
# file). No AI help block, no setup-help.txt.
# $1 step text, $2 hint (landlock|clt|wifi|sudo|"").
magpie_fail() {
  step=$1
  hint=${2:-}
  hint_line=""
  case $hint in
    landlock)
      hint_line="If the error mentions Landlock: close Ubuntu, open Windows PowerShell, run wsl --update, wait for it, reopen Ubuntu, run this file again."
      ;;
    clt)
      hint_line="Run: softwareupdate --list - then run this file again."
      ;;
    wifi)
      hint_line="Room Wi-Fi may need a browser login: open any website in your browser first, or use your phone hotspot, then run this file again."
      ;;
    sudo)
      hint_line="The password you typed was never accepted. Use your own login/administrator password, then run this file again."
      ;;
  esac
  logfile="$MAGPIE_SETUP_DIR/setup-log.txt"
  magpie_say ""
  magpie_say "SETUP FAILED (twice, reproducible): $step"
  if [ -n "$hint_line" ]; then
    magpie_say "  $hint_line"
  fi
  magpie_say "  system: $(magpie_sys_string) | $(uname -m)"
  magpie_say "  last log line: $(tail -n 1 "$logfile" 2>/dev/null)"
  magpie_say "  everything else: $logfile"
  exit 1
}

# Step still failing after retries: pass 1 -> one retry pass in a fresh
# process; pass 2 -> the failure verdict. Never a third pass.
magpie_step_failed() {
  step=$1
  hint=${2:-}
  magpie_log "step failed after retries: $step"
  if [ "${MAGPIE_PASS:-1}" = "2" ]; then
    magpie_fail "$step" "$hint"
  fi
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
  pidfile="$MAGPIE_SETUP_DIR/.keepalive.pid"
  old=$(cat "$pidfile" 2>/dev/null || echo "")
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    return 0
  fi
  (
    trap - EXIT INT TERM
    i=0
    while [ "$i" -lt 90 ]; do
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
  magpie_fail "password was never accepted" "sudo"
}

# ---------------- legacy state sweep ----------------

# Older script versions kept ALL course state under ~/magpie. That
# folder is the clone's home now, so every normal run sweeps it clean:
# state worth keeping is MOVED into the work dir (log history: append
# when both exist; a work-dir marker always wins and the old copy is
# dropped), junk with no value at a new path is DELETED. Best-effort
# throughout (2>/dev/null, || true) - the sweep never fails a setup,
# and it runs before the fast-path check so a migrated
# .setup-finished is visible to it. It matches EXACTLY these names
# (plus the setup-dl-* glob): a stray unknown file is left where it
# is, so the clone guard still reacts to it exactly as before.
# (setup-magpie.sh has the same function plus its own hidden handle
# file and relocation folder - that state never exists here.)
magpie_sweep_legacy() {
  old="$HOME/magpie"
  if [ -f "$old/setup-log.txt" ]; then
    if [ -f "$MAGPIE_SETUP_DIR/setup-log.txt" ]; then
      cat "$old/setup-log.txt" >> "$MAGPIE_SETUP_DIR/setup-log.txt" \
        2>/dev/null || true
      rm -f "$old/setup-log.txt" 2>/dev/null || true
    else
      mv "$old/setup-log.txt" "$MAGPIE_SETUP_DIR/setup-log.txt" \
        2>/dev/null || true
    fi
  fi
  for kept in .setup-fullrun-ok .setup-finished; do
    if [ -f "$old/$kept" ]; then
      if [ -f "$MAGPIE_SETUP_DIR/$kept" ]; then
        rm -f "$old/$kept" 2>/dev/null || true
      else
        mv "$old/$kept" "$MAGPIE_SETUP_DIR/$kept" 2>/dev/null || true
      fi
    fi
  done
  rm -f "$old"/setup-dl-* "$old/opencode-dl.tgz" "$old/nono-dl.tar.gz" \
    "$old/setup-help.txt" "$old/setup-help-profile.json" \
    "$old/.keepalive.pid" 2>/dev/null || true
  rm -rf "$old/opencode-extract" "$old/nono-extract" "$old/.setup.lock" \
    2>/dev/null || true
  return 0
}

# ---------------- lock + traps ----------------

magpie_arm_traps() {
  trap 'exit 130' INT TERM
  trap 'magpie_cleanup' EXIT
}

magpie_stop_keepalive() {
  pidfile="$MAGPIE_SETUP_DIR/.keepalive.pid"
  if [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
    fi
    rm -f "$pidfile"
    # The pidfile proves a sudo prompt happened: killing the refresher
    # alone is not enough, sudo remembers the password for minutes.
    # -k drops the cached credential (it never prompts itself). Without
    # a pidfile this stays a no-op - the fast path touches sudo never.
    command -v sudo >/dev/null 2>&1 && sudo -k >/dev/null 2>&1 || true
  fi
}

# Only the lock owner may clean: a second window that exits with
# "already running" must not kill the FIRST run's sudo keep-alive.
# The keep-alive only ever starts once the lock is held; the fast path
# stops a stale one via the explicit call in magpie_launch.
magpie_cleanup() {
  lock="$MAGPIE_SETUP_DIR/.setup.lock"
  if [ -f "$lock/pid" ] && [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then
    magpie_stop_keepalive
    rm -rf "$lock"
  fi
}

magpie_take_lock() {
  lock="$MAGPIE_SETUP_DIR/.setup.lock"
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

magpie_check_disk() {
  free_kb=$(df -Pk "$MAGPIE_SETUP_DIR" | awk 'NR==2 {print $4}')
  free_gb=$((free_kb / 1024 / 1024))
  if [ "$free_gb" -ge "$MAGPIE_DISK_MIN_GB" ]; then
    magpie_log "disk: $free_gb GB free"
    return 0
  fi
  if [ "$(uname)" = "Darwin" ]; then
    magpie_fail "low disk (${free_gb} GB free - empty the Trash and delete big files)"
  fi
  magpie_fail "low disk (${free_gb} GB free - free space in WINDOWS (C: drive) first)"
}

magpie_require_pins() {
  for v in "$OPENCODE_VERSION" "$OPENCODE_SHA256_DARWIN_ARM64" \
    "$OPENCODE_SHA256_DARWIN_X64" "$OPENCODE_SHA256_LINUX_ARM64" \
    "$OPENCODE_SHA256_LINUX_X64" "$NONO_VERSION" "$NONO_PACK_VERSION" \
    "$NONO_SHA256_AARCH64_APPLE_DARWIN" "$NONO_SHA256_X86_64_APPLE_DARWIN" \
    "$NONO_SHA256_AARCH64_UNKNOWN_LINUX_GNU" "$NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU"; do
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
  if ! grep -qF "$dir" "$rc" 2>/dev/null; then
    magpie_rc_newline "$rc"
    # shellcheck disable=SC2016  # $PATH must stay literal in the rc line.
    printf 'export PATH="%s:$PATH"\n' "$dir" >> "$rc"
    export PATH="$dir:$PATH"
    return 0
  fi
  export PATH="$dir:$PATH"
  return 1
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
        magpie_say "Added $bin to PATH in $MAGPIE_RC (also active in this run)."
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

# ---------------- OS branches (before the tools) ----------------

magpie_apt_body() {
  magpie_sudo_warm || return 1
  sudo apt-get update || return 1
  sudo apt-get install -y -o Acquire::Retries=3 git curl || return 1
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
    magpie_say_progress "apt update (git, curl)" "about 1-2 min"
    if ! magpie_retry 3 magpie_apt_body; then
      magpie_step_failed "apt git curl" "wifi"
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
    magpie_step_failed "Xcode Command Line Tools" "clt"
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
  tmp="$MAGPIE_SETUP_DIR/opencode-dl.tgz"
  dir="$MAGPIE_SETUP_DIR/opencode-extract"
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
    magpie_step_failed "opencode install" "wifi"
  fi
  magpie_fix_bin_path opencode
  magpie_say "OK: opencode $OPENCODE_VERSION installed"
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
  tmp="$MAGPIE_SETUP_DIR/nono-dl.tar.gz"
  dir="$MAGPIE_SETUP_DIR/nono-extract"
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
    magpie_step_failed "nono install" "wifi"
  fi
  magpie_fix_bin_path nono
  magpie_say "OK: nono $NONO_VERSION installed"
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
  if [ -f "$file" ] && cmp -s "$tmp" "$file" && [ -z "${MAGPIE_REPAIR:-}" ]; then
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

# ---------------- nono profile ----------------

magpie_nono_pack_version() {
  sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' \
    "$HOME/.config/nono/packages/nolabs-ai/opencode/package.json" 2>/dev/null \
    | head -n 1
}

# Pull the pinned pack version (MAGPIE_PACK_FORCE: existing install).
# The installed package.json must then report exactly the pin.
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
  if [ -n "${MAGPIE_REPAIR:-}" ]; then
    MAGPIE_PACK_FORCE=1
  elif [ -f "$marker" ]; then
    if [ "$(magpie_nono_pack_version)" = "$NONO_PACK_VERSION" ]; then
      magpie_log "nono profile opencode: already pulled"
      return 0
    fi
    magpie_log "nono pack version drift: got $(magpie_nono_pack_version), want $NONO_PACK_VERSION"
    MAGPIE_PACK_FORCE=1
  fi
  magpie_say_progress "nono profile" "about 1 min"
  if ! magpie_retry 3 magpie_nono_pull; then
    magpie_step_failed "nono profile pull" "wifi"
  fi
  # Pin keeps the pack out of `nono update`: the sandbox policy stays
  # exactly as pinned until this script raises the pin. Best effort.
  nono pin nolabs-ai/opencode >/dev/null 2>&1 \
    || magpie_log "nono pack pin failed - updates not blocked, tell the TA"
  magpie_say "OK: nono profile opencode pulled ($NONO_PACK_VERSION)"
}

# ---------------- magpie clone ----------------

magpie_clone_body() {
  repo="$HOME/magpie"
  # The entry no longer creates ~/magpie: only this step (the clone
  # itself) may make the folder the clone lives in.
  mkdir -p "$repo" || return 1
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

magpie_clone_magpie() {
  if [ -d "$HOME/magpie/.git" ]; then
    if [ "$(git -C "$HOME/magpie" remote get-url origin 2>/dev/null)" \
      != "$MAGPIE_MAGPIE_URL" ]; then
      magpie_fail "magpie folder exists but is not a magpie clone - move it away or delete it"
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
      # Belt-and-braces: the legacy sweep at entry moves the shared
      # housekeeping names out of ~/magpie before the guard runs, but
      # the allowlist stays as the setup-magpie.sh guard's list
      # verbatim - a file the sweep could not remove (or state from an
      # older distributed copy arriving between sweep and clone) must
      # never block the clone of an otherwise clean folder.
      # setup-help.txt + setup-help-profile.json: copies distributed
      # before the AI help block was removed may have left them there
      # (the .json held a rejected profile - written exactly by the
      # runs that died at the profile step, BEFORE any clone).
      # setup-dl-* / .setup-fullrun-ok: downloads of a hard-killed
      # setup-magpie.sh run (SIGHUP/SIGKILL skip its EXIT trap) and its
      # full-run marker.
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
    magpie_step_failed "magpie clone" "wifi"
  fi
  magpie_say "OK: magpie cloned"
}

# ---------------- sandbox smoke test + marker ----------------

magpie_sandbox_smoke() {
  # shellcheck disable=SC2016  # $HOME/$HU_API_KEY expand in the child, not here.
  ( cd "$HOME/magpie" && nono run --profile nolabs-ai/opencode --allow-cwd --silent -- \
    sh -c 'command -v opencode >/dev/null && test -r "$HOME/.config/opencode/opencode.json" && test -n "$HU_API_KEY"' )
}

magpie_sandbox_smoke_step() {
  magpie_log "sandbox smoke test (gates the finish marker)"
  if ! magpie_retry 3 magpie_sandbox_smoke; then
    hint=""
    if [ "$MAGPIE_OS" = "linux" ]; then
      hint=landlock
    fi
    magpie_step_failed "sandbox smoke" "$hint"
  fi
  {
    date '+%Y-%m-%d %H:%M:%S'
    nono --version 2>/dev/null || true
    opencode --version 2>/dev/null || true
  } > "$MAGPIE_SETUP_DIR/.setup-finished"
}

# ---------------- launch ----------------

magpie_launch() {
  # No warm sudo credential may live on while opencode runs: the
  # sandboxed agent must never be able to reuse it.
  magpie_stop_keepalive
  if ! command -v opencode >/dev/null 2>&1 && [ -x "$HOME/.opencode/bin/opencode" ]; then
    export PATH="$HOME/.opencode/bin:$PATH"
  fi
  if ! command -v nono >/dev/null 2>&1 && [ -x "$HOME/.nono/bin/nono" ]; then
    export PATH="$HOME/.nono/bin:$PATH"
  fi
  cd "$HOME/magpie" || magpie_fail "cannot enter $HOME/magpie"
  # Both paths end here (fast path and a fresh install): one line that
  # says the machine is ready, before opencode takes over the terminal.
  magpie_say "OK: setup complete - starting opencode in $HOME/magpie"
  start=$(date +%s)
  nono run --profile nolabs-ai/opencode --allow-cwd -- opencode >&4 2>&4
  code=$?
  secs=$(( $(date +%s) - start ))
  magpie_log "launch: exit $code after ${secs}s"
  if [ "$code" -eq 0 ] || [ "$secs" -ge "$MAGPIE_QUICKFAIL_SECS" ]; then
    exit 0
  fi
  if [ -n "${MAGPIE_REPAIR:-}" ]; then
    hint=""
    if [ "$MAGPIE_OS" = "linux" ]; then
      hint=landlock
    fi
    magpie_fail "sandbox did not come up even after repair" "$hint"
  fi
  magpie_say "[$(magpie_now)] - startup problem, repairing automatically, about 1 min"
  MAGPIE_REPAIR=1
  MAGPIE_PASS=2
  export MAGPIE_REPAIR MAGPIE_PASS
  if [ -n "${MAGPIE_SELF:-}" ]; then
    # The new process must start with the real terminal, not the log.
    exec 1>&4 2>&4
    exec bash "$MAGPIE_SELF"
  fi
  magpie_setup_path
  exit 1
}

# ---------------- paths ----------------

magpie_fast_path_ok() {
  if [ -n "${MAGPIE_FORCE_SETUP:-}" ] || [ -n "${MAGPIE_REPAIR:-}" ]; then
    return 1
  fi
  if [ ! -f "$MAGPIE_SETUP_DIR/.setup-finished" ]; then
    return 1
  fi
  if ! magpie_clone_ok; then
    return 1
  fi
  if ! magpie_resolve_opencode >/dev/null; then
    return 1
  fi
  if ! magpie_resolve_nono >/dev/null; then
    return 1
  fi
  if [ ! -f "$HOME/.config/nono/packages/nolabs-ai/opencode/package.json" ]; then
    return 1
  fi
  if [ "$(magpie_nono_pack_version)" != "$NONO_PACK_VERSION" ]; then
    return 1
  fi
  if [ ! -f "$HOME/.config/opencode/opencode.json" ]; then
    return 1
  fi
  return 0
}

magpie_setup_path() {
  if [ "$(id -u)" = "0" ]; then
    magpie_fail "do not run as root - run: bash ~/magpie-opencode.sh"
  fi
  magpie_require_pins
  magpie_check_disk
  magpie_take_lock
  magpie_step_os_base
  magpie_install_opencode
  magpie_install_nono
  if ! magpie_write_opencode_config; then
    magpie_step_failed "opencode config"
  fi
  magpie_pull_nono_profile
  magpie_clone_magpie
  magpie_sandbox_smoke_step
  magpie_launch
}

magpie_main() {
  case $(uname) in
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
  if magpie_fast_path_ok; then
    magpie_log "fast path: essentials found, launching"
    magpie_launch
  fi
  magpie_setup_path
}

# Resolve this file's absolute path, for the fresh-process passes.
magpie_entry() {
  MAGPIE_SELF=""
  if [ -f "$0" ]; then
    # shellcheck disable=SC1007  # CDPATH= applies to cd only, not an assignment.
    dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
    if [ -n "$dir" ]; then
      MAGPIE_SELF="$dir/$(basename -- "$0")"
    fi
  fi
  magpie_arm_traps
  if ! mkdir -p "$MAGPIE_SETUP_DIR" 2>/dev/null; then
    magpie_fail "cannot create ~/setup-magpie - check disk space and folder rights"
  fi
  # Move state an older script version left in ~/magpie out of the
  # clone's folder, then drop the junk names (best-effort, silent) -
  # BEFORE the fast-path check, so a migrated .setup-finished counts.
  magpie_sweep_legacy
  magpie_main ${1+"$@"} >> "$MAGPIE_SETUP_DIR/setup-log.txt" 2>&1
}

if [ -z "${MAGPIE_SOURCED:-}" ]; then
  exec 4>&1
  magpie_entry ${1+"$@"}
fi
