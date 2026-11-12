#!/usr/bin/env bash
# Offline harness for magpie-opencode.sh. Fake HOME, stub binaries only.
# Nothing touches the network.
set -u
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../magpie-opencode.sh"
RUNROOT="$HERE/../.tmp/testrun"
rm -rf "$RUNROOT"
mkdir -p "$RUNROOT"
# Canonicalize: the script's cd folds ".." away, paths must match.
RUNROOT=$(cd "$RUNROOT" && pwd)

PASS_N=0
FAIL_N=0
ok() { PASS_N=$((PASS_N + 1)); printf '  ok: %s\n' "$1"; }
no() { FAIL_N=$((FAIL_N + 1)); printf '  NOT OK: %s\n' "$1"; }
sec() { printf '\n== %s ==\n' "$1"; }

grep_ok() { if grep -q "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 [want: $3]"; fi; }
grep_no() { if grep -q "$3" "$2" 2>/dev/null; then no "$1 [unwanted: $3]"; else ok "$1"; fi; }
ret_is()  { if [ "$RET" = "$2" ]; then ok "$1 (exit $RET)"; else no "$1 (exit $RET want $2)"; fi; }
cnt_is()  {
  local c
  c=$(grep -c "$2" "$3" 2>/dev/null || true)
  c=${c:-0}
  if [ "$c" = "$4" ]; then ok "$1 (count $c)"; else no "$1 (count $c want $4)"; fi
}
file_ok() { if [ -e "$2" ]; then ok "$1"; else no "$1"; fi; }
nofile_ok() { if [ ! -e "$2" ]; then ok "$1"; else no "$1"; fi; }

# Linux only: the stub archives carry linux builds (macOS gets live
# tests, spec 8). Exit 77 marks "skipped, not failed".
if [ "$(uname)" != "Linux" ]; then
  echo "harness: Linux-only host required - skipped" >&2
  exit 77
fi

map_target() {
  case $(uname -m) in
    x86_64)
      # The pinned linux-x64 opencode build needs AVX2 (script check
      # at magpie_opencode_target). Without it the install steps die -
      # skip instead of reporting a false failure.
      if ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then
        echo "harness: CPU lacks AVX2 - install tests unsupported - skipped" >&2
        exit 77
      fi
      OC_TARGET=linux-x64
      NONO_TRIPLE=x86_64-unknown-linux-gnu
      PIN_OC=OPENCODE_SHA256_LINUX_X64
      PIN_NONO=NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU
      ;;
    aarch64)
      OC_TARGET=linux-arm64
      NONO_TRIPLE=aarch64-unknown-linux-gnu
      PIN_OC=OPENCODE_SHA256_LINUX_ARM64
      PIN_NONO=NONO_SHA256_AARCH64_UNKNOWN_LINUX_GNU
      ;;
    *) echo "harness: unsupported host arch - skipped" >&2; exit 77 ;;
  esac
}

new_env() {
  ENV=$(mktemp -d "$RUNROOT/env.XXXXXX")
  export ENV
  FAKE_HOME="$ENV/home"
  FAKE_BIN="$ENV/bin"
  STATE="$ENV/state"
  export STATE
  export TMPDIR="$ENV/tmp"
  mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$STATE" "$STATE/archives" "$STATE/binlib" "$TMPDIR"

  # --- installable binaries (NOT on PATH - only inside the archives) ---
  cat > "$STATE/binlib/opencode" <<'EOS'
#!/bin/sh
echo "opencode-stub 9.9.9"
EOS
  cat > "$STATE/binlib/nono" <<'EOS'
#!/bin/sh
echo "nono $*" >> "$STATE/nono.log"
case "$1" in
  --version) echo "nono-stub 9.9.9"; exit 0 ;;
  pull)
    c="$STATE/pull_count"
    n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$c"
    if [ "$n" -le "${STUB_NONO_PULL_FAILS:-0}" ]; then exit 1; fi
    ref=""
    for a in "$@"; do
      case $a in nolabs-ai/opencode*) ref=$a ;; esac
    done
    ver=${ref#*@}
    [ "$ver" = "$ref" ] && ver=latest
    mkdir -p "$HOME/.config/nono/packages/nolabs-ai/opencode"
    echo "{\"name\":\"opencode\",\"version\":\"$ver\"}" \
      > "$HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
    exit 0
    ;;
  run)
    case "$*" in
      *--silent*) exit "${STUB_NONO_SMOKE_EXIT:-0}" ;;
    esac
    # Keep-alive state AT the launch instant: the discriminating
    # evidence that the script stops it before opencode starts.
    if [ -f "$HOME/magpie/.keepalive.pid" ]; then
      echo alive >> "$STATE/keepalive_at_launch.txt"
    else
      echo dead >> "$STATE/keepalive_at_launch.txt"
    fi
    c="$STATE/launch_count"
    n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$c"
    echo "launch#$n PATH=$PATH HU=$HU_API_KEY CWD=$PWD" >> "$STATE/launch.txt"
    sleep "${STUB_NONO_LAUNCH_SLEEP:-0}"
    if [ "$n" -le "${STUB_NONO_LAUNCH_FAILS:-0}" ]; then
      exit "${STUB_NONO_LAUNCH_EXIT:-7}"
    fi
    exit "${STUB_NONO_LAUNCH_EXIT2:-0}"
    ;;
esac
exit 0
EOS
  chmod 755 "$STATE/binlib"/*

  # --- stubs on PATH ---
  cat > "$FAKE_BIN/sudo" <<'EOS'
#!/bin/sh
echo "sudo $*" >> "$STATE/sudo.log"
if [ "$1" = "-n" ]; then
  if [ "${STUB_SUDO_N_OK:-1}" = "1" ] || [ -f "$STATE/sudo_stamp" ]; then
    exit 0
  fi
  exit 1
fi
if [ "$1" = "-v" ]; then
  c="$STATE/sudo_v_count"
  n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$c"
  if [ "$n" -le "${STUB_SUDO_V_FAILS:-0}" ]; then exit 1; fi
  touch "$STATE/sudo_stamp"
  exit 0
fi
exit 0
EOS
  cat > "$FAKE_BIN/curl" <<'EOS'
#!/bin/sh
prev=""
out=""
url=""
for a in "$@"; do
  case $prev in -o) out=$a ;; esac
  case $a in http*|https*) url=$a ;; esac
  prev=$a
done
echo "$url" >> "$STATE/curl.log"
if [ -n "$url" ] && [ -n "$out" ]; then
  base=$(basename "$url")
  c="$STATE/dl_count_$base"
  n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$c"
  if [ "$n" -le "${STUB_CURL_DL_FAILS:-0}" ]; then exit 22; fi
  src="$STATE/archives/$base"
  bad=${STUB_BAD_ARCHIVE:-0}
  case $base in
    nono-*) if [ "${STUB_BAD_NONO:-0}" = "1" ]; then bad=1; fi ;;
  esac
  if [ "$bad" = "1" ] && [ -f "$src" ]; then
    src="$STATE/archives/bad.bin"
  fi
  if [ ! -f "$src" ]; then exit 22; fi
  cp "$src" "$out"
  exit 0
fi
exit 0
EOS
  cat > "$FAKE_BIN/df" <<'EOS'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "stub 1000 500 ${STUB_DF_AVAIL_KB:-200000000} 1% /fake"
EOS
  cat > "$FAKE_BIN/xcode-select" <<'EOS'
#!/bin/sh
exit "${STUB_XCODE_SELECT:-0}"
EOS
  cat > "$FAKE_BIN/softwareupdate" <<'EOS'
#!/bin/sh
echo "softwareupdate $*" >> "$STATE/su.log"
if [ "${1:-}" = "--list" ]; then
  echo "* Label: Command Line Tools for Xcode 15.0-15.0"
  echo "* Label: Command Line Tools for Xcode 16.2-16.2"
  exit 0
fi
exit 0
EOS
  cat > "$FAKE_BIN/sysctl" <<'EOS'
#!/bin/sh
echo 1
EOS
  cat > "$FAKE_BIN/ldd" <<'EOS'
#!/bin/sh
echo "ldd (Ubuntu GLIBC 2.39-0ubuntu8)"
EOS
  cat > "$FAKE_BIN/id" <<'EOS'
#!/bin/sh
if [ "${STUB_ID_ROOT:-0}" = "1" ] && [ "${1:-}" = "-u" ]; then
  echo 0
  exit 0
fi
exec /usr/bin/id "$@"
EOS
  chmod 755 "$FAKE_BIN"/*

  # --- fake release archives with real binaries inside ---
  mkdir -p "$ENV/build_oc/package/bin" "$ENV/build_nono/nono-9.9.9/bin"
  cp "$STATE/binlib/opencode" "$ENV/build_oc/package/bin/opencode"
  cp "$STATE/binlib/nono" "$ENV/build_nono/nono-9.9.9/bin/nono"
  chmod 755 "$ENV/build_oc/package/bin/opencode" "$ENV/build_nono/nono-9.9.9/bin/nono"
  tar -czf "$STATE/archives/cli-$OC_TARGET-9.9.9.tgz" -C "$ENV/build_oc" package/bin/opencode
  tar -czf "$STATE/archives/nono-v9.9.9-$NONO_TRIPLE.tar.gz" \
    -C "$ENV/build_nono" "nono-9.9.9/bin/nono"
  OC_SHA=$(sha256sum "$STATE/archives/cli-$OC_TARGET-9.9.9.tgz" | cut -d ' ' -f 1)
  NONO_SHA=$(sha256sum "$STATE/archives/nono-v9.9.9-$NONO_TRIPLE.tar.gz" | cut -d ' ' -f 1)
  echo "wrong contents for checksum mismatch tests" > "$STATE/archives/bad.bin"

  # --- local git origin for the magpie clone ---
  git init --bare -q -b main "$STATE/origin.git"
  git clone -q "file://$STATE/origin.git" "$ENV/seed" 2>/dev/null
  echo "readme" > "$ENV/seed/README.md"
  git -C "$ENV/seed" add README.md >/dev/null
  git -C "$ENV/seed" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  git -C "$ENV/seed" push -q origin main >/dev/null 2>&1

  # --- runnable copy of the script with test pins (any current values) ---
  sed -e 's|^OPENCODE_VERSION=.*|OPENCODE_VERSION="9.9.9"|' \
      -e 's|^NONO_VERSION=.*|NONO_VERSION="9.9.9"|' \
      -e 's|^NONO_PACK_VERSION=.*|NONO_PACK_VERSION="9.9.9"|' \
      -e "s|^$PIN_OC=.*|$PIN_OC=\"$OC_SHA\"|" \
      -e "s|^$PIN_NONO=.*|$PIN_NONO=\"$NONO_SHA\"|" \
      "$SCRIPT" > "$ENV/magpie.sh"
  chmod +x "$ENV/magpie.sh"
}

base_env() {
  export HOME="$FAKE_HOME"
  export PATH="$FAKE_BIN:/usr/bin:/bin"
  export MAGPIE_RETRY_SECS=0 MAGPIE_RETRY_SECS2=0 MAGPIE_PASS_SECS=0
  export MAGPIE_KEEPALIVE_SECS=0.05 MAGPIE_QUICKFAIL_SECS=2
  export MAGPIE_SUDO_RETRY_SECS=0
  export MAGPIE_MAGPIE_URL="file://$STATE/origin.git"
  unset MAGPIE_SOURCED MAGPIE_SELF MAGPIE_PASS MAGPIE_REPAIR MAGPIE_FORCE_SETUP
}

fill_pins() {
  OPENCODE_VERSION=9.9.9
  NONO_VERSION=9.9.9
  NONO_PACK_VERSION=9.9.9
  OPENCODE_SHA256_DARWIN_ARM64=deadbeef
  OPENCODE_SHA256_DARWIN_X64=deadbeef
  OPENCODE_SHA256_LINUX_ARM64=deadbeef
  OPENCODE_SHA256_LINUX_X64=deadbeef
  NONO_SHA256_AARCH64_APPLE_DARWIN=deadbeef
  NONO_SHA256_X86_64_APPLE_DARWIN=deadbeef
  NONO_SHA256_AARCH64_UNKNOWN_LINUX_GNU=deadbeef
  NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU=deadbeef
  eval "$PIN_OC=\$OC_SHA"
  eval "$PIN_NONO=\$NONO_SHA"
}

# Run the real script file end to end (entry point, fast path, execs).
run_e2e() {
  (
    base_env
    if [ "$#" -gt 0 ]; then
      export "$@"
    fi
    bash "$ENV/magpie.sh" > "$STATE/screen.txt" 2> "$STATE/screen_err.txt"
  )
  RET=$?
}

# Source the script and run FN_BODY (unit-level). fd 4 -> screen.txt.
run_fn() {
  (
    base_env
    export MAGPIE_SOURCED=1 MAGPIE_SELF=""
    for a in "$@"; do
      export "$a"
    done
    . "$SCRIPT"
    fill_pins
    magpie_arm_traps
    mkdir -p "$FAKE_HOME/magpie"
    eval "$FN_BODY" >> "$FAKE_HOME/magpie/setup-log.txt" 2>&1
  ) 4> "$STATE/screen.txt"
  RET=$?
}

make_installed() {
  mkdir -p "$FAKE_HOME/.opencode/bin" "$FAKE_HOME/.nono/bin" \
    "$FAKE_HOME/.config/opencode" \
    "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode" \
    "$FAKE_HOME/magpie"
  # Real single-commit repo: the fast path demands a resolvable HEAD,
  # the clone guard demands a matching origin (base_env's URL).
  git -C "$FAKE_HOME/magpie" init -q
  git -C "$FAKE_HOME/magpie" remote add origin "file://$STATE/origin.git"
  git -C "$FAKE_HOME/magpie" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m init
  cp "$STATE/binlib/opencode" "$FAKE_HOME/.opencode/bin/opencode"
  cp "$STATE/binlib/nono" "$FAKE_HOME/.nono/bin/nono"
  chmod 755 "$FAKE_HOME/.opencode/bin/opencode" "$FAKE_HOME/.nono/bin/nono"
  echo '{"model":"hu/llm3"}' > "$FAKE_HOME/.config/opencode/opencode.json"
  echo '{"name":"opencode","version":"9.9.9"}' > "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
  echo "marker" > "$FAKE_HOME/magpie/.setup-finished"
}

map_target

# ============================================================
sec "syntax"
# ============================================================
if bash -n "$SCRIPT" 2>/dev/null; then ok "bash -n"; else no "bash -n"; fi
if dash -n "$SCRIPT" 2>/dev/null; then ok "dash -n"; else no "dash -n"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s sh "$SCRIPT" >/dev/null 2>&1; then ok "shellcheck"; else no "shellcheck"; fi
else
  echo "  (shellcheck not installed - skipped)"
fi

# ============================================================
sec "placeholder pin guard"
# ============================================================
new_env
FN_BODY='OPENCODE_SHA256_DARWIN_X64=TBD; magpie_require_pins' run_fn
ret_is "pins TBD aborts" 1
grep_ok "help block shown" "$STATE/screen.txt" "script incomplete: pinned versions/checksums missing"
nofile_ok "no lock created" "$FAKE_HOME/magpie/.setup.lock"

# ============================================================
sec "disk guard"
# ============================================================
new_env
FN_BODY='magpie_check_disk' run_fn STUB_DF_AVAIL_KB=1000000
ret_is "low disk aborts" 1
grep_ok "windows hint" "$STATE/screen.txt" "WINDOWS (C: drive)"
nofile_ok "no install attempt" "$FAKE_HOME/.opencode"
new_env
FN_BODY='magpie_check_disk' run_fn STUB_DF_AVAIL_KB=200000000
ret_is "enough disk passes" 0

# ============================================================
sec "root guard"
# ============================================================
new_env
FN_BODY='magpie_setup_path' run_fn STUB_ID_ROOT=1
ret_is "root run aborts" 1
grep_ok "root message" "$STATE/screen.txt" "do not run as root"

# ============================================================
sec "lock"
# ============================================================
new_env
mkdir -p "$FAKE_HOME/magpie/.setup.lock"
sleep 60 &
LIVEPID=$!
echo "$LIVEPID" > "$FAKE_HOME/magpie/.setup.lock/pid"
FN_BODY='magpie_take_lock' run_fn
kill "$LIVEPID" 2>/dev/null
ret_is "live lock exits 0" 0
grep_ok "heads-up line" "$STATE/screen.txt" "already running in another window"
cnt_is "single line" "already running" "$STATE/screen.txt" 1
file_ok "other lock untouched" "$FAKE_HOME/magpie/.setup.lock/pid"
new_env
mkdir -p "$FAKE_HOME/magpie/.setup.lock"
echo 999999 > "$FAKE_HOME/magpie/.setup.lock/pid"
FN_BODY='magpie_take_lock; [ "$(cat "$HOME/magpie/.setup.lock/pid")" = "$$" ]' run_fn
ret_is "stale lock reclaimed silently" 0

# ============================================================
sec "retry helper"
# ============================================================
new_env
FN_BODY='flaky() { c="$STATE/f"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$c"; [ "$n" -gt 2 ]; }; magpie_retry 3 flaky' run_fn
ret_is "2 fails then success" 0
new_env
FN_BODY='alwaysfail() { return 1; }; magpie_retry 3 alwaysfail' run_fn
ret_is "persistent fail returns 1" 1
grep_ok "3 attempts logged" "$FAKE_HOME/magpie/setup-log.txt" "attempt 3/3"

# ============================================================
sec "sudo loop + keep-alive"
# ============================================================
new_env
FN_BODY='magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0 STUB_SUDO_V_FAILS=4
ret_is "sudo succeeds after 4 bad tries" 0
cnt_is "retry line 4x" "Password not accepted" "$STATE/screen.txt" 4
grep_no "no help block" "$STATE/screen.txt" "##"
new_env
FN_BODY='magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0 STUB_SUDO_V_FAILS=99
ret_is "sudo cap blocks" 1
grep_ok "help block at cap" "$STATE/screen.txt" "##"
cnt_is "6 rounds" "Password not accepted" "$STATE/screen.txt" 6
new_env
FN_BODY='magpie_sudo_warm' run_fn STUB_SUDO_N_OK=1
ret_is "warm timestamp no prompt" 0
grep_no "no prompt line" "$STATE/screen.txt" "asked now"
nofile_ok "keepalive only after ask" "$FAKE_HOME/magpie/.keepalive.pid"
new_env
FN_BODY='magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0
ret_is "prompt starts keepalive" 0
grep_ok "prompt line" "$STATE/screen.txt" "Type it blind"
sleep 0.3
kp=$(cat "$FAKE_HOME/magpie/.keepalive.pid" 2>/dev/null || echo "")
if [ -n "$kp" ] && kill -0 "$kp" 2>/dev/null; then
  ok "no-lock exit leaves keep-alive and pidfile"
else
  no "no-lock exit leaves keep-alive and pidfile"
fi
[ -n "$kp" ] && kill "$kp" 2>/dev/null
rm -f "$FAKE_HOME/magpie/.keepalive.pid"
new_env
make_installed
FN_BODY='magpie_sudo_warm; magpie_launch' run_fn STUB_SUDO_N_OK=0
ret_is "launch after prompt exits 0" 0
grep_ok "launch stopped keep-alive" "$STATE/keepalive_at_launch.txt" "dead"
nofile_ok "keepalive pidfile gone after launch" "$FAKE_HOME/magpie/.keepalive.pid"

# ============================================================
sec "cleanup ownership"
# ============================================================
# Owner (lock held) exit: stops its keep-alive, removes the lock.
new_env
FN_BODY='magpie_take_lock; magpie_start_keepalive; cat "$HOME/magpie/.keepalive.pid" > "$STATE/ka.pid"' run_fn
ret_is "owner run exits 0" 0
sleep 0.2
kp=$(cat "$STATE/ka.pid" 2>/dev/null || echo "")
nofile_ok "owner exit removes pidfile" "$FAKE_HOME/magpie/.keepalive.pid"
nofile_ok "owner exit removes lock" "$FAKE_HOME/magpie/.setup.lock"
if [ -n "$kp" ] && kill -0 "$kp" 2>/dev/null; then no "owner exit kills keep-alive"; else ok "owner exit kills keep-alive"; fi
# Non-owner exit ("already running"): zero side effects on the
# owner's keep-alive, pidfile and lock - the escalated baseline bug.
new_env
mkdir -p "$FAKE_HOME/magpie/.setup.lock"
sleep 60 &
OWNERPID=$!
echo "$OWNERPID" > "$FAKE_HOME/magpie/.setup.lock/pid"
sleep 60 &
KAPID=$!
echo "$KAPID" > "$FAKE_HOME/magpie/.keepalive.pid"
FN_BODY='magpie_take_lock' run_fn
ret_is "non-owner exits 0" 0
grep_ok "non-owner heads-up line" "$STATE/screen.txt" "already running in another window"
file_ok "non-owner leaves pidfile" "$FAKE_HOME/magpie/.keepalive.pid"
if kill -0 "$KAPID" 2>/dev/null; then ok "non-owner leaves owner keep-alive alive"; else no "non-owner leaves owner keep-alive alive"; fi
file_ok "non-owner leaves lock" "$FAKE_HOME/magpie/.setup.lock/pid"
kill "$OWNERPID" "$KAPID" 2>/dev/null

# ============================================================
sec "TERM trap cleanup"
# ============================================================
new_env
(
  base_env
  export MAGPIE_SOURCED=1
  . "$SCRIPT"
  exec 4>/dev/null
  mkdir -p "$FAKE_HOME/magpie"
  magpie_start_keepalive
  magpie_take_lock
  sleep 5 &
  wait $!
) 2>/dev/null &
tp=$!
sleep 0.5
kp=$(cat "$FAKE_HOME/magpie/.keepalive.pid" 2>/dev/null || echo "")
kill -TERM "$tp" 2>/dev/null
wait "$tp" 2>/dev/null
rc=$?
[ -n "$kp" ] && ok "keepalive was running" || no "keepalive was running"
[ "$rc" = 130 ] && ok "exit code 130 on TERM" || no "exit code 130 on TERM (got $rc)"
nofile_ok "lock removed" "$FAKE_HOME/magpie/.setup.lock"
if [ -n "$kp" ] && kill -0 "$kp" 2>/dev/null; then no "keepalive killed"; else ok "keepalive killed"; fi

# ============================================================
sec "config write"
# ============================================================
new_env
CFG="$FAKE_HOME/.config/opencode/opencode.json"
FN_BODY='magpie_write_opencode_config' run_fn
ret_is "writes fresh config" 0
grep_ok "model preselected" "$CFG" '"model": "hu/llm3"'
FN_BODY='magpie_write_opencode_config' run_fn
grep_ok "identical skip logged" "$FAKE_HOME/magpie/setup-log.txt" "already in place"
nofile_ok "no bak on skip" "$CFG.bak"
new_env
mkdir -p "$FAKE_HOME/.config/opencode"
echo '{"broken": true}' > "$FAKE_HOME/.config/opencode/opencode.json"
CFG="$FAKE_HOME/.config/opencode/opencode.json"
FN_BODY='magpie_write_opencode_config' run_fn
file_ok "foreign config backed up" "$CFG.bak"
grep_ok "foreign replaced" "$CFG" '"model": "hu/llm3"'
new_env
CFG="$FAKE_HOME/.config/opencode/opencode.json"
FN_BODY='magpie_write_opencode_config; magpie_write_opencode_config' run_fn MAGPIE_REPAIR=1
file_ok "repair rewrites even when identical" "$CFG.bak"

# ============================================================
sec "fast path checks"
# ============================================================
new_env
make_installed
FN_BODY='magpie_fast_path_ok' run_fn
ret_is "all present -> fast" 0
new_env; make_installed; rm -f "$FAKE_HOME/magpie/.setup-finished"
FN_BODY='magpie_fast_path_ok' run_fn; ret_is "no marker -> setup" 1
new_env; make_installed; rm -rf "$FAKE_HOME/magpie/.git"
FN_BODY='magpie_fast_path_ok' run_fn; ret_is "no git -> setup" 1
new_env; make_installed; rm -f "$FAKE_HOME/.opencode/bin/opencode"
FN_BODY='magpie_fast_path_ok' run_fn; ret_is "no opencode -> setup" 1
new_env; make_installed; rm -f "$FAKE_HOME/.nono/bin/nono"
FN_BODY='magpie_fast_path_ok' run_fn; ret_is "no nono -> setup" 1
new_env; make_installed; rm -f "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
FN_BODY='magpie_fast_path_ok' run_fn; ret_is "no profile -> setup" 1
new_env; make_installed; rm -f "$FAKE_HOME/.config/opencode/opencode.json"
FN_BODY='magpie_fast_path_ok' run_fn; ret_is "no config -> setup" 1
new_env; make_installed
sed -i 's|"version":"9.9.9"|"version":"8.8.8"|' "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
FN_BODY='magpie_fast_path_ok' run_fn; ret_is "pack version drift -> setup" 1
new_env; make_installed
FN_BODY='magpie_fast_path_ok' run_fn MAGPIE_FORCE_SETUP=1; ret_is "FORCE_SETUP blocks fast" 1
new_env; make_installed
FN_BODY='magpie_fast_path_ok' run_fn MAGPIE_REPAIR=1; ret_is "REPAIR blocks fast" 1

# ============================================================
sec "E2E day-one setup"
# ============================================================
new_env
run_e2e
ret_is "day one exits 0" 0
S="$STATE/screen.txt"
grep_ok "opencode OK line" "$S" "OK: opencode 9.9.9 installed"
grep_ok "nono OK line" "$S" "OK: nono 9.9.9 installed"
grep_ok "profile OK line" "$S" "OK: nono profile opencode pulled"
grep_ok "clone OK line" "$S" "OK: magpie cloned"
grep_ok "PATH note opencode" "$S" "Added opencode to PATH"
cnt_is "exactly 4 heads-ups" "installing" "$S" 4
grep_no "apt skipped no heads-up" "$S" "apt update"
grep_no "no help block" "$S" "##"
file_ok "marker written" "$FAKE_HOME/magpie/.setup-finished"
grep_ok "marker has versions" "$FAKE_HOME/magpie/.setup-finished" "nono-stub 9.9.9"
file_ok "opencode installed exec" "$FAKE_HOME/.opencode/bin/opencode"
file_ok "nono installed exec" "$FAKE_HOME/.nono/bin/nono"
cnt_is "rc line once opencode" ".opencode/bin" "$FAKE_HOME/.bashrc" 1
cnt_is "rc line once nono" ".nono/bin" "$FAKE_HOME/.bashrc" 1
grep_ok "clone checked out file" "$FAKE_HOME/magpie/README.md" "readme"
grep_ok "launch cwd" "$STATE/launch.txt" "CWD=$FAKE_HOME/magpie"
grep_ok "launch sees HU key" "$STATE/launch.txt" "HU=required-but-not-used"
grep_ok "launch sees installed dir" "$STATE/launch.txt" "$FAKE_HOME/.opencode/bin"
grep_ok "log launch line" "$FAKE_HOME/magpie/setup-log.txt" "launch: exit 0 after"
grep_ok "smoke uses --allow-cwd" "$STATE/nono.log" "run --profile nolabs-ai/opencode --allow-cwd --silent"
grep_ok "launch uses --allow-cwd" "$STATE/nono.log" "run --profile nolabs-ai/opencode --allow-cwd -- opencode"
nofile_ok "lock released" "$FAKE_HOME/magpie/.setup.lock"
grep_ok "pull uses pinned pack version" "$STATE/nono.log" "pull nolabs-ai/opencode@9.9.9"
grep_ok "pack pinned against updates" "$STATE/nono.log" "nono pin nolabs-ai/opencode"
nofile_ok "no sudo at all (apt skipped)" "$STATE/sudo.log"
grep_no "no blind prompt (apt skipped)" "$S" "Type it blind"
grep_ok "keep-alive dead at launch instant" "$STATE/keepalive_at_launch.txt" "dead"

# second run: fast path
run_e2e
ret_is "second run exits 0" 0
cnt_is "no heads-ups on fast path" "installing" "$STATE/screen.txt" 0
grep_ok "fast path logged" "$FAKE_HOME/magpie/setup-log.txt" "fast path: essentials found"
grep_ok "launch called again" "$STATE/launch.txt" "launch#2"
grep_no "no code name on screen" "$STATE/screen.txt" "code name"
run_e2e MAGPIE_FORCE_SETUP=1
ret_is "FORCE_SETUP reruns setup" 0
cnt_is "all steps skip (0 heads-ups)" "installing" "$STATE/screen.txt" 0
cnt_is "rc lines stay deduped" ".opencode/bin" "$FAKE_HOME/.bashrc" 1
grep_no "repair not triggered" "$STATE/screen.txt" "repairing"

# ============================================================
sec "E2E checksum mismatch (reproducible error)"
# ============================================================
new_env
run_e2e STUB_BAD_ARCHIVE=1
ret_is "corrupt download blocks" 1
S="$STATE/screen.txt"
grep_ok "help block" "$S" "##"
grep_ok "failed step named" "$S" "FAILED STEP (twice, reproducible): opencode install"
grep_ok "wifi hint" "$S" "Wi-Fi"
grep_no "no code name in help block" "$S" "code name"
cnt_is "retry heads-up once per pass" "retrying automatically" "$S" 1
cnt_is "failing step logged in both passes" "step failed after retries" "$FAKE_HOME/magpie/setup-log.txt" 2
n=$(cat "$STATE/dl_count_cli-$OC_TARGET-9.9.9.tgz" 2>/dev/null || echo 0)
[ "$n" = 6 ] && ok "6 download attempts (3+3 over 2 passes)" || no "download attempts: $n"
nofile_ok "no marker on failure" "$FAKE_HOME/magpie/.setup-finished"
grep_ok "help file saved" "$FAKE_HOME/magpie/setup-help.txt" "FAILED STEP"

# transient download failure passes silently
new_env
run_e2e STUB_CURL_DL_FAILS=1
ret_is "transient download failure heals" 0
grep_no "no failure heads-up" "$STATE/screen.txt" "retrying automatically"

# day one with an expired sudo timestamp: still zero prompts,
# because apt/CLT steps skip while git+curl are present
new_env
run_e2e STUB_BAD_ARCHIVE=1 STUB_SUDO_N_OK=0
cnt_is "asked blind never" "Type it blind" "$STATE/screen.txt" 0

# ============================================================
sec "E2E repair (force pull + config force-write)"
# ============================================================
new_env
run_e2e
ret_is "day one ok" 0
run_e2e MAGPIE_REPAIR=1 MAGPIE_PASS=2
ret_is "repair run exits 0" 0
grep_ok "repair force-pulls profile" "$STATE/nono.log" "pull --force nolabs-ai/opencode"
file_ok "repair backs up identical config" "$FAKE_HOME/.config/opencode/opencode.json.bak"
grep_no "repair never prompts sudo" "$STATE/screen.txt" "Type it blind"

# ============================================================
sec "E2E launch quick-fail -> repair -> relaunch"
# ============================================================
new_env
make_installed
run_e2e STUB_NONO_LAUNCH_FAILS=1
ret_is "quick-fail recovers on 2nd launch" 0
grep_ok "repair heads-up" "$STATE/screen.txt" "startup problem, repairing automatically"
grep_ok "force pull ran in repair" "$STATE/nono.log" "pull --force nolabs-ai/opencode"
file_ok "config force-written in repair" "$FAKE_HOME/.config/opencode/opencode.json.bak"
cnt_is "exactly two launches" "launch#" "$STATE/launch.txt" 2
grep_no "no lock conflict during repair" "$STATE/screen.txt" "already running"

new_env
make_installed
run_e2e STUB_NONO_LAUNCH_FAILS=99
ret_is "second quick-fail blocks" 1
grep_ok "help block after repair" "$STATE/screen.txt" "##"
cnt_is "exactly two launches total" "launch#" "$STATE/launch.txt" 2

new_env
make_installed
run_e2e STUB_NONO_LAUNCH_FAILS=99 STUB_NONO_LAUNCH_EXIT=5 STUB_NONO_LAUNCH_SLEEP=4
ret_is "slow non-zero exit is quiet" 0
cnt_is "single launch" "launch#" "$STATE/launch.txt" 1
grep_no "no repair" "$STATE/screen.txt" "repairing"

# ============================================================
sec "E2E smoke gate"
# ============================================================
new_env
make_installed
rm -f "$FAKE_HOME/magpie/.setup-finished"
run_e2e MAGPIE_FORCE_SETUP=1 STUB_NONO_SMOKE_EXIT=1
ret_is "smoke failure blocks" 1
grep_ok "step named" "$STATE/screen.txt" "FAILED STEP (twice, reproducible): sandbox smoke"
grep_ok "landlock hint on linux" "$STATE/screen.txt" "wsl --update"
nofile_ok "marker not written" "$FAKE_HOME/magpie/.setup-finished"
new_env
make_installed
rm -f "$FAKE_HOME/magpie/.setup-finished"
run_e2e MAGPIE_FORCE_SETUP=1
ret_is "smoke pass writes marker" 0
file_ok "marker written" "$FAKE_HOME/magpie/.setup-finished"

# ============================================================
sec "E2E magpie dir guards"
# ============================================================
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
echo "mine" > "$FAKE_HOME/magpie/important.txt"
run_e2e MAGPIE_FORCE_SETUP=1
ret_is "foreign dir blocks" 1
grep_ok "foreign dir message" "$STATE/screen.txt" "not a magpie clone"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
echo "log" > "$FAKE_HOME/magpie/setup-log.txt"
echo "help" > "$FAKE_HOME/magpie/setup-help.txt"
run_e2e MAGPIE_FORCE_SETUP=1
ret_is "own files only -> clone proceeds" 0
file_ok "clone recreated .git" "$FAKE_HOME/magpie/.git"
grep_ok "clone happened" "$STATE/screen.txt" "OK: magpie cloned"

new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
touch "$FAKE_HOME/magpie/opencode-dl.tgz" "$FAKE_HOME/magpie/nono-dl.tar.gz"
mkdir -p "$FAKE_HOME/magpie/opencode-extract" "$FAKE_HOME/magpie/nono-extract"
run_e2e MAGPIE_FORCE_SETUP=1
ret_is "install leftovers -> clone proceeds" 0
file_ok "clone recreated .git" "$FAKE_HOME/magpie/.git"

new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
git -C "$FAKE_HOME/magpie" init -q
git -C "$FAKE_HOME/magpie" remote add origin "file://$STATE/origin.git"
run_e2e MAGPIE_FORCE_SETUP=1
ret_is "interrupted clone healed on rerun" 0
grep_ok "heal logged" "$FAKE_HOME/magpie/setup-log.txt" "interrupted clone found"
grep_ok "clone checked out file" "$FAKE_HOME/magpie/README.md" "readme"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
git -C "$FAKE_HOME/magpie" init -q
git -C "$FAKE_HOME/magpie" remote add origin https://elsewhere.invalid/repo.git
run_e2e MAGPIE_FORCE_SETUP=1
ret_is "foreign origin in .git blocks" 1
grep_ok "foreign dir message" "$STATE/screen.txt" "not a magpie clone"
new_env
make_installed
git -C "$FAKE_HOME/magpie" update-ref -d HEAD 2>/dev/null
rm -f "$FAKE_HOME/magpie/README.md"
FN_BODY='magpie_fast_path_ok' run_fn
ret_is "git dir without commits -> setup" 1

new_env
FN_BODY='mkdir -p "$HOME/magpie"; magpie_clone_body && magpie_clone_body' run_fn
ret_is "clone body idempotent twice" 0
new_env
FN_BODY='mkdir -p "$HOME/magpie"
git -C "$HOME/magpie" init -q
git -C "$HOME/magpie" remote add origin "$MAGPIE_MAGPIE_URL"
git -C "$HOME/magpie" fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
git -C "$HOME/magpie" branch main origin/main 2>/dev/null || true
magpie_clone_body' run_fn
ret_is "clone survives half-created re-entry" 0

# ============================================================
sec "E2E profile pull flakiness"
# ============================================================
new_env
run_e2e STUB_NONO_PULL_FAILS=1
ret_is "pull retry silent success" 0
grep_no "no pass-2 message" "$STATE/screen.txt" "retrying automatically"

# ============================================================
sec "E2E pack version drift -> force re-pull"
# ============================================================
new_env
make_installed
sed -i 's|"version":"9.9.9"|"version":"8.8.8"|' "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
run_e2e
ret_is "drift re-run exits 0" 0
grep_ok "drift force-pulls pinned" "$STATE/nono.log" "pull --force nolabs-ai/opencode@9.9.9"
grep_ok "installed version back at pin" "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json" '"version":"9.9.9"'
grep_no "drift still no sudo" "$STATE/sudo.log" "."

# ============================================================
sec "sourced step_failed: in-process pass 2"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; magpie_step_failed teststep' run_fn
ret_is "in-process pass 2 completes setup" 0
grep_ok "auto retry heads-up" "$STATE/screen.txt" "retrying automatically"
file_ok "marker written after pass 2" "$FAKE_HOME/magpie/.setup-finished"
new_env
FN_BODY='MAGPIE_PASS=2 magpie_step_failed teststep' run_fn
ret_is "pass 2 failure blocks" 1
grep_ok "help block after pass 2" "$STATE/screen.txt" "##"

new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; magpie_install_nono' run_fn STUB_BAD_NONO=1
ret_is "persistent nono fail blocks after 2 passes" 1
grep_ok "nono step named in help" "$STATE/screen.txt" \
  "FAILED STEP (twice, reproducible): nono install"
cnt_is "two failing passes only" "step failed after retries" "$FAKE_HOME/magpie/setup-log.txt" 2

# ============================================================
sec "macOS CLT branch (sourced, forced OS)"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; magpie_step_os_base' \
  run_fn STUB_XCODE_SELECT=1
ret_is "CLT install branch ran" 0
grep_ok "softwareupdate newest label" "$STATE/sudo.log" "softwareupdate --install Command Line Tools for Xcode 16.2"
grep_ok "CLT heads-up" "$STATE/screen.txt" "Xcode Command Line Tools, about 5-20 min"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; magpie_step_os_base' run_fn
ret_is "CLT skip when present" 0
grep_no "no heads-up when skipped" "$STATE/screen.txt" "installing"
nofile_ok "softwareupdate untouched" "$STATE/su.log"

# ============================================================
sec "nono archive layout discovery"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; NONO_VERSION=9.9.9; MAGPIE_NONO_TRIPLE=$NONO_TRIPLE; MAGPIE_NONO_SHA=$NONO_SHA; magpie_install_nono_body' run_fn
ret_is "nono member found via tar listing" 0
file_ok "nono placed" "$FAKE_HOME/.nono/bin/nono"

# ============================================================
sec "download temp-file guard"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; mkdir -p "$HOME/magpie"
cp "$STATE/archives/cli-$OC_TARGET-9.9.9.tgz" "$HOME/magpie/dl.tgz"
magpie_download "http://x/cli-$OC_TARGET-9.9.9.tgz" "$HOME/magpie/dl.tgz" "$OC_SHA"' run_fn
ret_is "intact temp file skips re-download" 0
grep_no "no request for the asset" "$STATE/curl.log" "cli-"
file_ok "temp file kept for the caller" "$FAKE_HOME/magpie/dl.tgz"
new_env
FN_BODY='MAGPIE_OS=linux; mkdir -p "$HOME/magpie"
echo partial > "$HOME/magpie/dl.tgz"
magpie_download "http://x/dl.tgz" "$HOME/magpie/dl.tgz" deadbeef' run_fn STUB_CURL_DL_FAILS=1
ret_is "failed download removes the temp file" 1
nofile_ok "no temp left to wedge a resume" "$FAKE_HOME/magpie/dl.tgz"

# ============================================================
printf '\n========================================\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_N" "$FAIL_N"
[ "$FAIL_N" = 0 ] || exit 1
exit 0
