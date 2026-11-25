#!/usr/bin/env bash
# Offline harness for setup-magpie.sh. Fake HOME, stub binaries only.
# Nothing touches the network (the curl stub records feed uploads locally).
set -u
umask 077

# Hermetic git: the tests create their own repos; the host's global or
# system gitconfig must never participate (git dies outright on an
# unreadable ~/.gitconfig, e.g. under a sandbox).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../setup-magpie.sh"
RUNROOT="$HERE/../.tmp/testrun-setup"
# Previous scratch moves aside instantly (rename), then a detached rm
# sweeps it while this run works. GPFS deletes cost seconds; blocking
# on them dominated the startup.
if [ -e "$RUNROOT" ]; then
  TRASH="$RUNROOT.old.$$"
  mv "$RUNROOT" "$TRASH"
  ( rm -rf "$TRASH" >/dev/null 2>&1 & )
fi
mkdir -p "$RUNROOT"
# Canonicalize: the script's cd folds ".." away, paths must match.
RUNROOT=$(cd "$RUNROOT" && pwd)

PASS_N=0
FAIL_N=0
ok() { PASS_N=$((PASS_N + 1)); printf '  ok: %s\n' "$1"; }
no() { FAIL_N=$((FAIL_N + 1)); printf '  NOT OK: %s\n' "$1"; }
sec() { printf '\n== %s ==\n' "$1"; }

grep_ok() { if grep -q -e "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 [want: $3]"; fi; }
grep_no() { if grep -q -e "$3" "$2" 2>/dev/null; then no "$1 [unwanted: $3]"; else ok "$1"; fi; }
ret_is()  { if [ "$RET" = "$2" ]; then ok "$1 (exit $RET)"; else no "$1 (exit $RET want $2)"; fi; }
cnt_is()  {
  local c
  c=$(grep -c -e "$2" "$3" 2>/dev/null || true)
  c=${c:-0}
  if [ "$c" = "$4" ]; then ok "$1 (count $c)"; else no "$1 (count $c want $4)"; fi
}
file_ok() { if [ -e "$2" ]; then ok "$1"; else no "$1"; fi; }
nofile_ok() { if [ ! -e "$2" ]; then ok "$1"; else no "$1"; fi; }
mode_is() {
  local m
  m=$(stat -c %a "$2" 2>/dev/null || echo none)
  if [ "$m" = "$3" ]; then ok "$1 (mode $m)"; else no "$1 (mode $m want $3)"; fi
}

# Bash 3.2 gate: flags bash4+ constructs plus the banned double
# bracket, dollar-RANDOM and the angle-paren process substitution
# (bash-3.2-valid but banned by design, spec 2). Bracketed first
# letters keep this pattern text from matching itself.
BASH32_PAT='[d]eclare -A|[l]ocal -A|[m]apfile|[r]eadarray|[&]>>|[|]&|[d]eclare -n|[l]ocal -n|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|@)|[<][(]|\$[R]ANDOM|\[\['
bash32_guard() {
  local hits
  hits=$(grep -nE "$BASH32_PAT" "$1" 2>/dev/null || true)
  if [ -z "$hits" ]; then
    ok "bash32 guard: $(basename "$1")"
  else
    no "bash32 guard: bash4+ constructs in $1"
    printf '%s\n' "$hits"
  fi
}

# Bounded polls instead of fixed sleeps (2s cap, 20ms steps).
wait_gone() {
  local i=0
  while [ -e "$1" ] && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
}
wait_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
}

# Linux only: the stub archives carry linux builds (macOS gets live
# tests, spec-setup-magpie.md). Exit 77 marks "skipped, not failed".
if [ "$(uname)" != "Linux" ]; then
  echo "harness: Linux-only host required - skipped" >&2
  exit 77
fi

map_target() {
  # Full E2E needs the script's x86_64 GAMS path (the pinned linux
  # build is x86_64 only - the script itself fails otherwise), and
  # the pinned linux-x64 opencode build needs AVX2 (script check at
  # magpie_opencode_target). Skip instead of reporting false failures.
  if [ "$(uname -m)" != "x86_64" ]; then
    echo "harness: x86_64 Linux host required (pinned GAMS build) - skipped" >&2
    exit 77
  fi
  if ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then
    echo "harness: CPU lacks AVX2 - install tests unsupported - skipped" >&2
    exit 77
  fi
  OC_TARGET=linux-x64
  NONO_TRIPLE=x86_64-unknown-linux-gnu
  PIN_OC=OPENCODE_SHA256_LINUX_X64
  PIN_NONO=NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU
}

# Shared fixture tree: stubs, archives, git origin, pinned script copy.
# Built once after map_target; new_env() clones it per scenario.
# All stubs resolve $STATE/$FAKE_BIN at run time (quoted heredocs),
# so the content is path-independent and clonable.
build_template() {
  TEMPLATE="$RUNROOT/template"
  rm -rf "$TEMPLATE"
  ENV="$TEMPLATE"
  FAKE_HOME="$ENV/home"
  FAKE_BIN="$ENV/bin"
  STATE="$ENV/state"
  export STATE FAKE_BIN
  MINBIN="$ENV/minbin"
  export TMPDIR="$ENV/tmp"
  mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$MINBIN" "$STATE" "$STATE/archives" "$STATE/binlib" "$TMPDIR"
  # Default supported release for the Ubuntu floor check: scenarios
  # override it by re-exporting MAGPIE_OS_RELEASE as a run_fn arg.
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$STATE/os-release"
  # Only these core tools exist for the tested script (host tex/pandoc/
  # Rscript/gams on PATH would shadow the stubs and trigger REAL downloads).
  for tool in bash cmp awk basename cat chmod cp cut date dirname env git \
    head ln ls mkdir mv od readlink rm sed sha256sum shasum sleep sort stat tail tar \
    tee gzip tr touch grep mktemp sh uname; do
    src=$(command -v "$tool" || true)
    [ -n "$src" ] && ln -sf "$src" "$MINBIN/$tool"
  done
  # The host true is an exec-incompatible launcher binary (bash falls
  # back to interpreting it -> 126). A real script stub is portable.
  printf '#!/bin/sh\nexit 0\n' > "$MINBIN/true"
  chmod 755 "$MINBIN/true"

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
    force=""
    for a in "$@"; do
      case $a in nolabs-ai/opencode*) ref=$a ;; --force) force=1 ;; esac
    done
    echo "pull force=$force ref=$ref" >> "$STATE/nono.log"
    ver=${ref#*@}
    [ "$ver" = "$ref" ] && ver=latest
    # Wrong-version sabotage knob: emulate a registry that hands back
    # a stale pack despite the pinned ref (script-side check must bite).
    [ -n "${STUB_NONO_PULL_WRONG_VER:-}" ] && ver="$STUB_NONO_PULL_WRONG_VER"
    mkdir -p "$HOME/.config/nono/packages/nolabs-ai/opencode"
    echo "{\"name\":\"opencode\",\"version\":\"$ver\"}" \
      > "$HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
    exit 0
    ;;
  pin) exit 0 ;;
  profile)
    if [ "${2:-}" = validate ]; then
      echo "validate $*" >> "$STATE/nono.log"
      if [ -n "${STUB_NONO_VALIDATE_ERR:-}" ]; then
        echo "$STUB_NONO_VALIDATE_ERR" >&2
      fi
      exit "${STUB_NONO_VALIDATE_EXIT:-0}"
    fi
    exit 0
    ;;
  run)
    case "$*" in
      *--check-only*)
        # Keep-alive state AT the gate instant: the discriminating
        # evidence that the script stops it before the sandbox runs.
        if [ -f "$HOME/setup-magpie/.keepalive.pid" ]; then
          echo alive >> "$STATE/keepalive_at_gate.txt"
        else
          echo dead >> "$STATE/keepalive_at_gate.txt"
        fi
        # Cached sudo credential AT the gate instant: no warm sudo may
        # survive into the sandboxed gate child.
        if [ -f "$STATE/sudo_stamp" ]; then
          echo warm >> "$STATE/sudo_at_gate.txt"
        else
          echo cool >> "$STATE/sudo_at_gate.txt"
        fi
        # Proxy for the sandboxed child's stdout: it must reach the
        # log ONLY (the script appends the gate output there and
        # keeps nothing on screen). The banner line stands for what
        # nono itself prints (version, pack, capability dump through
        # "Applying sandbox...") before the child runs.
        echo "NONO-BANNER-MARKER Applying sandbox..."
        echo "GATE-CHILD-OUTPUT-MARKER"
        exit "${STUB_NONO_GATE_EXIT:-0}"
        ;;
      *runscripts=default.R*)
        # Full-run request: probe the keep-alive the same way, then
        # re-enact the inner bash -c payload so the stub Rscript
        # fakes the run folder + artifacts.
        if [ -f "$HOME/setup-magpie/.keepalive.pid" ]; then
          echo alive >> "$STATE/keepalive_at_gate.txt"
        else
          echo dead >> "$STATE/keepalive_at_gate.txt"
        fi
        if [ -f "$STATE/sudo_stamp" ]; then
          echo warm >> "$STATE/sudo_at_gate.txt"
        else
          echo cool >> "$STATE/sudo_at_gate.txt"
        fi
        if [ "${STUB_FULLRUN_FAIL:-0}" = "1" ]; then exit 1; fi
        last=""
        for a in "$@"; do last=$a; done
        sh -c "$last"
        exit $?
        ;;
      *"library(lucode2)"*|*"renv::hydrate"*)
        # Readiness probe / hydrate repair request: replay the inner
        # bash -c payload under a sandbox marker, so the stub Rscript
        # scripts the library state (probe knobs, heal on repair).
        MAGPIE_SANDBOX_CHILD=1
        export MAGPIE_SANDBOX_CHILD
        last=""
        for a in "$@"; do last=$a; done
        sh -c "$last"
        exit $?
        ;;
    esac
    exit 0
    ;;
esac
exit 0
EOS
  cat > "$STATE/binlib/Rscript" <<'EOS'
#!/bin/sh
echo "Rscript $*" >> "$STATE/rscript.log"
case "$*" in
  *"cat(as.character(getRversion"*) echo 4.4.2; exit 0 ;;
  *normalizePath*)
    # Profile build's Renviron symlink resolution (Debian resolves
    # /usr/lib/R/etc/Renviron -> /etc/R/Renviron). The folder only
    # lands in the read list when it exists, so most scenarios
    # (no such dir) see no extra entry.
    echo "$HOME/etc-R"
    exit 0
    ;;
  *R.home*)
    # Profile build's directory query (R.home + .libPaths). The base
    # library under R-home must dedupe against it; R-site-lib is a
    # genuine extra. Only listed when the folders exist (the profile
    # gates them), so most scenarios see nothing.
    echo "$HOME/R-home"
    echo "$HOME/R-home/library"
    echo "$HOME/R-site-lib"
    exit 0
    ;;
  *getRversion*)
    if [ "${STUB_R_OLD:-0}" = "1" ]; then exit 1; fi
    exit 0
    ;;
  *"R CMD config FC"*)
    # magpie_r_fc's probe (R CMD config FC inside an Rscript -e snippet).
    # The stub IS R here, so it answers what that whole snippet would
    # print: the resolved FC path, and only when it is executable (the
    # file.access(p, 1) == 0 gate). STUB_FC_PATH unset/empty or not
    # executable = R has no usable Fortran compiler.
    if [ -n "${STUB_FC_PATH:-}" ] && [ -x "${STUB_FC_PATH}" ]; then
      printf '%s' "$STUB_FC_PATH"
    fi
    exit 0
    ;;
  *install_tinytex*)
    # The body's second call: version gate + install. Below 0.46 the
    # real tinytex still fetches the dead yihui.org prebuilt URL, so
    # the body quits(status = 1) BEFORE install_tinytex() - mirror
    # that: no tex folder appears. The default passes, so the older
    # scenarios keep seeing a plain successful install.
    v="${STUB_TINYTEX_VERSION:-0.56}"
    maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
    if [ "$maj" -gt 0 ] || { [ "$maj" -eq 0 ] && [ "$min" -ge 46 ]; }; then
      # Default mimics Linux (~/.TinyTeX); macOS tests point this at
      # $HOME/Library/TinyTeX (what tinytex::install_tinytex really uses).
      d="${STUB_TINYTEX_ROOT:-$HOME/.TinyTeX}/bin/x86_64-unknown-linux-gnu"
      mkdir -p "$d"
      printf '#!/bin/sh\necho stub-tex\n' > "$d/tex"
      chmod 755 "$d/tex"
      exit 0
    fi
    echo "Error: tinytex $v predates the GitHub-aware downloader" >&2
    exit 1
    ;;
  *"install.packages"*)
    # The body's first call: the CRAN refresh. The marker rides on
    # stdout exactly like real install chatter - scenarios grep it out
    # of the run log to prove the body silences nothing.
    echo "STUB-INSTALL-PACKAGES-MARKER"
    exit 0
    ;;
  *"library(lucode2)"*)
    # The library load test (the nono replay marks sandbox children):
    # scripted by STUB_PROBE_FAILS, broken by a crashing run, healed
    # by a done repair; the unsandboxed check answers STUB_RENV_EXIT.
    if [ -n "${MAGPIE_SANDBOX_CHILD:-}" ]; then
      if [ -f "$STATE/lib_healed" ]; then exit 0; fi
      if [ -f "$STATE/lib_broken" ]; then
        echo "Error in loadNamespace(t, c('gms', 'getLine')):" >&2
        echo "  there is no package called 'gms'" >&2
        exit 1
      fi
      c="$STATE/probe_count"; n=$(cat "$c" 2>/dev/null || echo 0)
      n=$((n + 1)); echo "$n" > "$c"
      if [ "$n" -le "${STUB_PROBE_FAILS:-0}" ]; then
        echo "Error in loadNamespace(t, c('gms', 'getLine')):" >&2
        echo "  there is no package called 'gms'" >&2
        exit 1
      fi
      exit 0
    fi
    exit "${STUB_RENV_EXIT:-0}"
    ;;
  *"renv::hydrate"*"rmarkdown"*)
    # The gate's repair: STUB_HYDRATE_EXIT=1 keeps the library broken.
    if [ -n "${MAGPIE_SANDBOX_CHILD:-}" ]; then
      if [ "${STUB_HYDRATE_EXIT:-0}" != "0" ]; then
        echo "Error: hydrate failed - course feed unreachable" >&2
        exit "${STUB_HYDRATE_EXIT}"
      fi
      : > "$STATE/lib_healed"
      exit 0
    fi
    exit 0
    ;;
  *"start.R"*"runscripts=default.R"*)
    # Optional stdin capture: proves the caller feeds the prompt answers.
    if [ "${STUB_FULLRUN_CAPTURE:-0}" = "1" ]; then
      cat > "$STATE/fullrun_stdin"
    fi
    # Simulated magpie run: a results folder named like
    # start_functions.R builds it (default_<timestamp>); the counter
    # keeps successive names unique and ordered.
    c="$STATE/run_counter"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$c"
    name=$(date -d "@$(( $(date +%s) + n ))" +%Y-%m-%d_%H.%M.%S 2>/dev/null) \
      || name=$(date +%Y-%m-%d_%H.%M.%S)
    d="$HOME/magpie/output/default_$name"
    # piamenv::stopIfLoaded stop (start.R answered y to "Update now?"
    # and the loaded gms got updated): STUB_FULLRUN_RESTART=1 stops on
    # the FIRST call only (the fresh second session runs normally),
    # =2 stops on EVERY call (proves the step's retry is capped).
    if [ "${STUB_FULLRUN_RESTART:-0}" = 2 ] \
    || { [ "${STUB_FULLRUN_RESTART:-0}" = 1 ] && [ "$n" = 1 ]; }; then
      echo "Error in piamenv::stopIfLoaded():"
      echo "  Please restart R."
      exit 1
    fi
    # I11 crash frame: a getLine prompt died on a missing namespace
    # (message text localized - the gate must key on the frame names
    # only). The crash is also what breaks the library for the retry.
    if [ "${STUB_FULLRUN_CRASH:-0}" = 2 ] \
    || { [ "${STUB_FULLRUN_CRASH:-0}" = 1 ] && [ "$n" = 1 ]; }; then
      echo "Error in loadNamespace(t, c('gms', 'getLine')):" >&2
      echo "  es gibt kein Paket namens 'gms'" >&2
      touch "$STATE/lib_broken"
      exit 1
    fi
    # ONE frame name only: the retry signature is keyed on
    # loadNamespace AND getLine - half a frame must never open it.
    if [ "${STUB_FULLRUN_ONEFRAME:-0}" = 1 ]; then
      echo "Error in loadNamespace(t, c('gms')):" >&2
      echo "  there is no package called 'gms'" >&2
      exit 1
    fi
    if [ "${STUB_FULLRUN_NOTHING:-0}" = "1" ]; then exit 0; fi
    mkdir -p "$d"
    touch "$d/fulldata.gdx" "$d/full.lst"
    if [ "${STUB_FULLRUN_NO_OUTPUT:-0}" = "1" ]; then exit 0; fi
    touch "$d/report.rds" "$d/report.mif"
    exit "${STUB_FULLRUN_RSCRIPT_EXIT:-0}"
    ;;
esac
exit 0
EOS
  cat > "$STATE/binlib/pandoc" <<'EOS'
#!/bin/sh
echo "pandoc 3.1.0"
EOS
  cat > "$STATE/binlib/pandoc-x" <<'EOS'
#!/bin/sh
echo "pandoc-x 3.1.0"
EOS
  cat > "$STATE/binlib/gfortran" <<'EOS'
#!/bin/sh
echo "gfortran-stub"
EOS
  # The banner text is env-switchable for the gams check table. A
  # gamslice.txt carrying the test course content - in the binary's
  # own folder (sysdir, read first) or the macOS user data folder -
  # flips the banner to the course one: licence scenarios ask the
  # same stub before and after the write.
  cat > "$STATE/binlib/gams" <<'EOS'
#!/bin/sh
banner="${STUB_GAMS_BANNER:-GAMS 54.6.1 - Licensee: Potsdam-Institut fuer Klimafolgenforschung - the installed license is valid.}"
me=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for s in "$me/gamslice.txt" "$HOME/Library/Application Support/GAMS/gamslice.txt"; do
  if [ -f "$s" ] && grep -q TEST-LICENCE-CONTENT "$s" 2>/dev/null; then
    banner="GAMS 54.6.1 - Licensee: Potsdam-Institut fuer Klimafolgenforschung - the installed license is valid."
    break
  fi
done
printf '%s\n' "$banner"
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
if [ "$1" = "-k" ]; then
  rm -f "$STATE/sudo_stamp"
  exit 0
fi
# Root's DAC override is not reproducible for a plain user: with this
# knob, write commands into the simulated "root-owned" (unwritable)
# folder succeed by relaxing its mode around the real command, and
# chown is a logged no-op - mirroring what real sudo would produce.
if [ "${STUB_SUDO_AS_ROOT:-0}" = 1 ]; then
  case "$1" in
    chown) exit 0 ;;
    cp|tee)
      dst=""
      for a in "$@"; do dst=$a; done
      dst_dir=$(dirname "$dst")
      mode=$(stat -c %a "$dst_dir" 2>/dev/null || echo "")
      [ -n "$mode" ] && chmod u+w "$dst_dir"
      "$@"
      ret=$?
      [ -n "$mode" ] && chmod "$mode" "$dst_dir"
      exit "$ret"
      ;;
  esac
fi
exec "$@"
EOS
  # caffeinate: logs the wrap, then runs the real command (mac path).
  cat > "$FAKE_BIN/caffeinate" <<'EOS'
#!/bin/sh
echo "caffeinate $*" >> "$STATE/caffeinate.log"
while [ $# -gt 0 ]; do
  case $1 in
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
EOS
  # curl: feed uploads (-T file = PUT) -> feed.log + feed_url.log
  # (credentials stripped up to the last @, as curl splits them; a
  # filled-in share link cannot leak into test artifacts);
  # archives -> state files. The upload branch emits
  # a response body (stdout unless -o /dev/null) and progress on stderr
  # (unless -s), so a script dropping either flag pollutes its own log.
  cat > "$FAKE_BIN/curl" <<'EOS'
#!/bin/sh
prev=""
out=""
url=""
up=""
for a in "$@"; do
  case $prev in -o) out=$a ;; -T) up=$a ;; esac
  case $a in http*|https*) url=$a ;; esac
  prev=$a
done
if [ -n "$up" ]; then
  cat "$up" >> "$STATE/feed.log"
  printf 'PUT %s\n' "$url" | sed -e 's|://[^/]*@|://|' >> "$STATE/feed_url.log"
  quiet=0
  for a in "$@"; do
    case $a in -s*|*silent*) quiet=1 ;; esac
  done
  if [ "$quiet" = 0 ]; then
    echo "stub-progress-noise" >&2
  fi
  if [ "$out" != "/dev/null" ]; then
    echo "stub-response-noise"
  fi
  exit "${STUB_FEED_FAIL:-0}"
fi
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
    *_sfx.exe|GAMS*.pkg) if [ "${STUB_BAD_GAMS:-0}" = "1" ]; then bad=1; fi ;;
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
  # apt-get: succeeds and "installs" the two tools the script checks.
  # STUB_APT_INSTALL_FAILS=N: the first N install calls exit 100
  # (update and dist-upgrade never fail) - drives the escalation path.
  cat > "$FAKE_BIN/apt-get" <<'EOS'
#!/bin/sh
echo "apt-get $*" >> "$STATE/apt.log"
if [ "${STUB_APT_FAIL:-0}" = "1" ]; then exit 100; fi
seen_install=0
for a in "$@"; do [ "$a" = install ] && seen_install=1; done
if [ "$seen_install" = 1 ]; then
  c="$STATE/apt_install_count"
  n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$c"
  if [ "$n" -le "${STUB_APT_INSTALL_FAILS:-0}" ]; then exit 100; fi
  for a in "$@"; do
    case $a in
      r-base) cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript" 2>/dev/null || true ;;
      pandoc) cp "$STATE/binlib/pandoc" "$FAKE_BIN/pandoc" 2>/dev/null || true ;;
    esac
  done
fi
exit 0
EOS
  # dpkg -s: prints an installed status by default; STUB_DPKG_MISSING
  # names one package whose query fails, STUB_DPKG_HALF a known but
  # half-configured one (real dpkg -s exits 0 there too).
  cat > "$FAKE_BIN/dpkg" <<'EOS'
#!/bin/sh
for a in "$@"; do
  if [ -n "${STUB_DPKG_MISSING:-}" ] && [ "$a" = "$STUB_DPKG_MISSING" ]; then
    exit 1
  fi
  if [ -n "${STUB_DPKG_HALF:-}" ] && [ "$a" = "$STUB_DPKG_HALF" ]; then
    echo "Package: $a"
    echo "Status: install ok half-configured"
    exit 0
  fi
done
echo "Status: install ok installed"
exit 0
EOS
  # installer: macOS .pkg stub; "installs" per-lookup tools by pkg name.
  cat > "$FAKE_BIN/installer" <<'EOS'
#!/bin/sh
echo "installer $*" >> "$STATE/installer.log"
if [ "${STUB_INSTALLER_FAIL:-0}" = "1" ]; then exit 1; fi
pkg=""
prev=""
for a in "$@"; do
  case $prev in -pkg) pkg=$a ;; esac
  prev=$a
done
case $(basename "${pkg:-none}") in
  setup-dl-R.pkg) cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript" ;;
  setup-dl-gfortran.pkg)
    if [ -n "${STUB_GF_TARGET:-}" ]; then
      # Off-PATH pkg target (the real one is /usr/local/gfortran/bin).
      mkdir -p "$STUB_GF_TARGET"
      cp "$STATE/binlib/gfortran" "$STUB_GF_TARGET/gfortran"
    else
      cp "$STATE/binlib/gfortran" "$FAKE_BIN/gfortran"
    fi ;;
  setup-dl-pandoc.pkg) cp "$STATE/binlib/pandoc" "$FAKE_BIN/pandoc" ;;
esac
exit 0
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
  echo "wrong contents for checksum mismatch tests" > "$STATE/archives/bad.bin"

  # Fake macOS pkgs (basenames match the pinned URLs exactly).
  echo "fake R arm64 pkg"  > "$STATE/archives/R-4.6.2-arm64.pkg"
  echo "fake R x86 pkg"    > "$STATE/archives/R-4.6.2-x86_64.pkg"
  echo "fake gfortran pkg" > "$STATE/archives/gfortran-14.2-universal.pkg"
  echo "fake pandoc arm"   > "$STATE/archives/pandoc-3.14-arm64-macOS.pkg"
  echo "fake pandoc x86"   > "$STATE/archives/pandoc-3.14-x86_64-macOS.pkg"
  echo "fake gams pkg"     > "$STATE/archives/GAMS54.6.1.pkg"

  # Fake GAMS linux self-extractor: extracts a working gams stub that
  # shows the banner of the gamslice beside it - and, like the real
  # installer, ships the demo gamslice with the fresh install.
  cat > "$STATE/archives/linux_x64_64_sfx.exe" <<'EOS'
#!/bin/sh
mkdir -p gams54.6.1_linux_x64_64_sfx
printf '%s\n' 'DEMO-SLICE-HANDS-OFF' > gams54.6.1_linux_x64_64_sfx/gamslice.txt
cat > gams54.6.1_linux_x64_64_sfx/gams <<'EGAMS'
#!/bin/sh
banner="${STUB_GAMS_BANNER:-*** Error: no license file found}"
me=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for s in "$me/gamslice.txt" "$HOME/Library/Application Support/GAMS/gamslice.txt"; do
  if [ -f "$s" ] && grep -q TEST-LICENCE-CONTENT "$s" 2>/dev/null; then
    banner="GAMS 54.6.1 - Licensee: Potsdam-Institut fuer Klimafolgenforschung - the installed license is valid."
    break
  elif [ -f "$s" ] && grep -q DEMO-SLICE-HANDS-OFF "$s" 2>/dev/null; then
    banner='Licensee: GAMS Demo, for EULA and demo limitations see G240131/0001CB-GEN
The installed license is valid.'
    break
  fi
done
printf '%s\n' "$banner"
EGAMS
chmod 755 gams54.6.1_linux_x64_64_sfx/gams
exit 0
EOS
  chmod 755 "$STATE/archives/linux_x64_64_sfx.exe"

  sha_of() { sha256sum "$1" | cut -d ' ' -f 1; }
  OC_SHA=$(sha_of "$STATE/archives/cli-$OC_TARGET-9.9.9.tgz")
  NONO_SHA=$(sha_of "$STATE/archives/nono-v9.9.9-$NONO_TRIPLE.tar.gz")
  GAMS_EXE_SHA=$(sha_of "$STATE/archives/linux_x64_64_sfx.exe")
  GAMS_PKG_SHA=$(sha_of "$STATE/archives/GAMS54.6.1.pkg")
  GF_SHA=$(sha_of "$STATE/archives/gfortran-14.2-universal.pkg")
  R_PKG_SHA=$(sha_of "$STATE/archives/R-4.6.2-x86_64.pkg")
  R_PKG_SHA_ARM=$(sha_of "$STATE/archives/R-4.6.2-arm64.pkg")
  PD_SHA=$(sha_of "$STATE/archives/pandoc-3.14-x86_64-macOS.pkg")
  PD_SHA_ARM=$(sha_of "$STATE/archives/pandoc-3.14-arm64-macOS.pkg")

  # --- local git origin for the magpie clone ---
  git init --bare -q -b main "$STATE/origin.git"
  git clone -q "file://$STATE/origin.git" "$ENV/seed" 2>/dev/null
  echo "readme" > "$ENV/seed/README.md"
  # No root renv.lock in the seed: a root lock never exists in course
  # clones, so the clone E2E must prove the flow without one.
  git -C "$ENV/seed" add README.md >/dev/null
  git -C "$ENV/seed" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  git -C "$ENV/seed" push -q origin main >/dev/null 2>&1

  # --- runnable copy of the script with test pins + licence states ---
  sed -e 's|^OPENCODE_VERSION=.*|OPENCODE_VERSION="9.9.9"|' \
      -e 's|^NONO_VERSION=.*|NONO_VERSION="9.9.9"|' \
      -e 's|^NONO_PACK_VERSION=.*|NONO_PACK_VERSION="9.9.9"|' \
      -e "s|^$PIN_OC=.*|$PIN_OC=\"$OC_SHA\"|" \
      -e "s|^$PIN_NONO=.*|$PIN_NONO=\"$NONO_SHA\"|" \
      -e "s|^GAMS_SHA256_LINUX_X64=.*|GAMS_SHA256_LINUX_X64=\"$GAMS_EXE_SHA\"|" \
      -e "s|^GAMS_SHA256_DARWIN_ARM64=.*|GAMS_SHA256_DARWIN_ARM64=\"$GAMS_PKG_SHA\"|" \
      -e "s|^GAMS_SHA256_DARWIN_X64=.*|GAMS_SHA256_DARWIN_X64=\"$GAMS_PKG_SHA\"|" \
      -e "s|^GFORTRAN_SHA256=.*|GFORTRAN_SHA256=\"$GF_SHA\"|" \
      -e "s|^R_SHA256_DARWIN_ARM64=.*|R_SHA256_DARWIN_ARM64=\"$R_PKG_SHA_ARM\"|" \
      -e "s|^R_SHA256_DARWIN_X64=.*|R_SHA256_DARWIN_X64=\"$R_PKG_SHA\"|" \
      -e "s|^PANDOC_SHA256_DARWIN_ARM64=.*|PANDOC_SHA256_DARWIN_ARM64=\"$PD_SHA_ARM\"|" \
      -e "s|^PANDOC_SHA256_DARWIN_X64=.*|PANDOC_SHA256_DARWIN_X64=\"$PD_SHA\"|" \
      "$SCRIPT" > "$ENV/magpie.sh"
  chmod +x "$ENV/magpie.sh"
  # Replace only the heredoc line, not the marker check in
  # magpie_licence_embedded.
  sed '/^__PASTE_CONTENTS_OF_gamslice.txt_HERE__$/s|__PASTE_CONTENTS_OF_gamslice.txt_HERE__|TEST-LICENCE-CONTENT|' \
    "$ENV/magpie.sh" > "$ENV/magpie_lic.sh"
  chmod +x "$ENV/magpie_lic.sh"
  # Placeholder line deleted but nothing pasted: a blank heredoc must
  # count as NOT embedded (magpie_licence_embedded).
  sed '/^__PASTE_CONTENTS_OF_gamslice.txt_HERE__$/d' \
    "$ENV/magpie.sh" > "$ENV/magpie_lic_blank.sh"
  chmod +x "$ENV/magpie_lic_blank.sh"
  # Teacher left the feed URL empty -> uploads must be off entirely.
  sed 's|^STATUS_URL=.*|STATUS_URL=""|' \
    "$ENV/magpie_lic.sh" > "$ENV/magpie_nofeed.sh"
  chmod +x "$ENV/magpie_nofeed.sh"

  SRC="$SCRIPT"
  E2E_SCRIPT="$ENV/magpie.sh"
}

# Per-scenario clone of the template via hardlinks (cp -al): cheap on
# GPFS, and safe because scenario writes only create new files, never
# modify shipped ones. Host tools in minbin keep their exec behaviour.
new_env() {
  ENV=$(mktemp -d "$RUNROOT/env.XXXXXX")
  export ENV
  FAKE_HOME="$ENV/home"
  FAKE_BIN="$ENV/bin"
  STATE="$ENV/state"
  export STATE FAKE_BIN
  MINBIN="$ENV/minbin"
  export TMPDIR="$ENV/tmp"
  mkdir -p "$FAKE_HOME" "$MINBIN" "$TMPDIR"
  # Hardlinks throughout: scenarios only ever CREATE files inside the
  # env (logs, counters, installed binaries), never edit shipped ones in
  # place, so shared inodes cannot leak state between scenarios.
  cp -al "$TEMPLATE/state" "$STATE"
  cp -al "$TEMPLATE/bin/." "$FAKE_BIN/"
  cp -al "$TEMPLATE/minbin/." "$MINBIN/"
  cp -l "$TEMPLATE/magpie.sh" "$ENV/magpie.sh"
  cp -l "$TEMPLATE/magpie_lic.sh" "$ENV/magpie_lic.sh"
  cp -l "$TEMPLATE/magpie_lic_blank.sh" "$ENV/magpie_lic_blank.sh"
  cp -l "$TEMPLATE/magpie_nofeed.sh" "$ENV/magpie_nofeed.sh"
  SRC="$SCRIPT"
  E2E_SCRIPT="$ENV/magpie.sh"
}

base_env() {
  export HOME="$FAKE_HOME"
  export PATH="$FAKE_BIN:$MINBIN"
  export MAGPIE_RETRY_SECS=0 MAGPIE_RETRY_SECS2=0 MAGPIE_PASS_SECS=0
  export MAGPIE_KEEPALIVE_SECS=0.05 MAGPIE_SUDO_RETRY_SECS=0
  export MAGPIE_MAGPIE_URL="file://$STATE/origin.git"
  # Fixed supported release: the Ubuntu floor check must never read
  # the host's /etc/os-release. Scenario args may re-export
  # MAGPIE_OS_RELEASE (they are applied after this default).
  export MAGPIE_OS_RELEASE="$STATE/os-release"
  unset MAGPIE_SOURCED MAGPIE_SELF MAGPIE_PASS MAGPIE_PASS1_STEP MAGPIE_PACK_FORCE
  unset MAGPIE_CHECK_ONLY STUB_GAMS_BANNER MAGPIE_FULL_RUN
}

fill_pins() {
  OPENCODE_VERSION=9.9.9
  OPENCODE_SHA256_DARWIN_ARM64=deadbeef
  OPENCODE_SHA256_DARWIN_X64=deadbeef
  OPENCODE_SHA256_LINUX_ARM64=deadbeef
  OPENCODE_SHA256_LINUX_X64=deadbeef
  NONO_VERSION=9.9.9
  NONO_PACK_VERSION=9.9.9
  NONO_SHA256_AARCH64_APPLE_DARWIN=deadbeef
  NONO_SHA256_X86_64_APPLE_DARWIN=deadbeef
  NONO_SHA256_AARCH64_UNKNOWN_LINUX_GNU=deadbeef
  NONO_SHA256_X86_64_UNKNOWN_LINUX_GNU=deadbeef
  GAMS_VERSION=54.6.1
  GAMS_URL_LINUX_X64=http://x/linux_x64_64_sfx.exe
  GAMS_SHA256_LINUX_X64="$GAMS_EXE_SHA"
  GAMS_URL_DARWIN_ARM64=http://x/GAMS54.6.1.pkg
  GAMS_SHA256_DARWIN_ARM64="$GAMS_PKG_SHA"
  GAMS_URL_DARWIN_X64=http://x/GAMS54.6.1.pkg
  GAMS_SHA256_DARWIN_X64="$GAMS_PKG_SHA"
  GFORTRAN_VERSION=14.2
  GFORTRAN_URL=http://x/gfortran-14.2-universal.pkg
  GFORTRAN_SHA256="$GF_SHA"
  R_VERSION=4.6.2
  R_URL_DARWIN_ARM64=http://x/R-4.6.2-arm64.pkg
  R_SHA256_DARWIN_ARM64="$R_PKG_SHA_ARM"
  R_URL_DARWIN_X64=http://x/R-4.6.2-x86_64.pkg
  R_SHA256_DARWIN_X64="$R_PKG_SHA"
  PANDOC_VERSION=3.14
  PANDOC_URL_DARWIN_ARM64=http://x/pandoc-3.14-arm64-macOS.pkg
  PANDOC_SHA256_DARWIN_ARM64="$PD_SHA_ARM"
  PANDOC_URL_DARWIN_X64=http://x/pandoc-3.14-x86_64-macOS.pkg
  PANDOC_SHA256_DARWIN_X64="$PD_SHA"
  eval "$PIN_OC=\$OC_SHA"
  eval "$PIN_NONO=\$NONO_SHA"
}

# Run the real script file end to end (entry point, execs).
run_e2e() {
  (
    base_env
    if [ "$#" -gt 0 ]; then
      export "$@"
    fi
    bash "$E2E_SCRIPT" > "$STATE/screen.txt" 2> "$STATE/screen_err.txt"
  )
  RET=$?
}

# Print --script-hash output: the masked build hash, via the script's
# own early-exit flag (no log, no feed, no state).
script_hash() {
  (
    base_env
    bash "$1" --script-hash
  )
}

# Source the script and run FN_BODY (unit-level). fd 4 -> screen.txt.
run_fn() {
  (
    base_env
    export MAGPIE_SOURCED=1 MAGPIE_SELF=""
    for a in "$@"; do
      export "$a"
    done
    . "$SRC"
    fill_pins
    magpie_arm_traps
    mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
    eval "$FN_BODY" </dev/null >> "$FAKE_HOME/setup-magpie/setup-log.txt" 2>&1
  ) 4> "$STATE/screen.txt"
  RET=$?
}

# Tools that make the checks green (the library probe too: the stub
# loads unless STUB_RENV_EXIT=1).
make_tools() {
  cp "$STATE/binlib/gams" "$FAKE_BIN/gams"
  cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
  cp "$STATE/binlib/pandoc" "$FAKE_BIN/pandoc"
  printf '#!/bin/sh\necho tex\n' > "$FAKE_BIN/tex"
  chmod 755 "$FAKE_BIN/tex"
}

# nono command on PATH for unit tests that call it directly
# (E2E gets it via the install step + PATH export).
put_nono() { cp "$STATE/binlib/nono" "$FAKE_BIN/nono"; }

# The real GAMS demo banner shape (documented wording - no capture of a
# live demo banner exists): the demo NAMES a licensee and calls itself
# valid, so matching Licensee / "license is valid" alone can never keep
# it. Demo/expired wording must outrank both.
DEMO_BANNER='Licensee: GAMS Demo, for EULA and demo limitations see G240131/0001CB-GEN
The installed license is valid.'


# A finished install (for rerun/clone-guard tests).
make_installed() {
  mkdir -p "$FAKE_HOME/.opencode/bin" "$FAKE_HOME/.nono/bin" \
    "$FAKE_HOME/.config/opencode" \
    "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode" \
    "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
  git -C "$FAKE_HOME/magpie" init -q
  git -C "$FAKE_HOME/magpie" remote add origin "file://$STATE/origin.git"
  git -C "$FAKE_HOME/magpie" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m init
  cp "$STATE/binlib/opencode" "$FAKE_HOME/.opencode/bin/opencode"
  cp "$STATE/binlib/nono" "$FAKE_HOME/.nono/bin/nono"
  chmod 755 "$FAKE_HOME/.opencode/bin/opencode" "$FAKE_HOME/.nono/bin/nono"
  echo '{"model":"hu/llm3"}' > "$FAKE_HOME/.config/opencode/opencode.json"
  echo '{"name":"opencode","version":"9.9.9"}' > "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
  # GAMS installed WITH the course gamslice: reruns of the placeholder
  # script must read a healthy machine (banner shows the course
  # licensee), like after a filled-script install actually ran.
  mkdir -p "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx"
  cp "$STATE/binlib/gams" "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gams"
  printf '%s\n' 'TEST-LICENCE-CONTENT' \
    > "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
}

map_target
build_template

# ============================================================
sec "syntax"
# ============================================================
if bash -n "$SCRIPT" 2>/dev/null; then ok "bash -n"; else no "bash -n"; fi
bash32_guard "$SCRIPT"
bash32_guard "$HERE/test-setup-magpie.sh"
# Guard self-test: the pattern must actually FLAG the banned idioms -
# a silently narrowed BASH32_PAT would keep this suite green while the
# spec 2 machine-enforcement quietly dies. Idioms are assembled from
# parts so the guard never sees its own fixture text as a violation.
b32_bb='['
b32_d='$'
b32_lp='('
b32_dl='declare'
for b32_idiom in "$b32_bb$b32_bb x ]]" "$b32_d""RANDOM=1" \
  "diff <${b32_lp}true)" "${b32_dl} -A cfg"; do
  printf '%s\n' "$b32_idiom" > "$RUNROOT/bash32-fixture.sh"
  if grep -qE "$BASH32_PAT" "$RUNROOT/bash32-fixture.sh"; then
    ok "bash32 pattern flags: $b32_idiom"
  else
    no "bash32 pattern flags: $b32_idiom"
  fi
done
SHELLCHECK=""
if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK=shellcheck
elif [ -x "$HERE/shellcheck" ]; then
  SHELLCHECK="$HERE/shellcheck"
fi
if [ -n "$SHELLCHECK" ]; then
  if "$SHELLCHECK" -s bash "$SCRIPT" >/dev/null 2>&1; then ok "shellcheck"; else no "shellcheck"; fi
else
  echo "  (shellcheck not found - skipped)"
fi

# ============================================================
sec "feed target guard"
# ============================================================
# The end anchor doubles as the credential guard: pasting the share
# token and password into STATUS_URL (the teacher's paste step before
# distributing) no longer matches this line.
grep_ok "committed feed URL holds no credentials" "$SCRIPT" \
  '^STATUS_URL="https://cloud\.pik-potsdam\.de/public\.php/webdav"$'

# ============================================================
sec "placeholder pin guard"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; R_SHA256_DARWIN_X64=TBD; magpie_require_pins' run_fn
ret_is "pins TBD aborts" 1
grep_ok "failure verdict shown" "$STATE/screen.txt" "script incomplete: pinned versions/checksums missing"
nofile_ok "no lock created" "$FAKE_HOME/setup-magpie/.setup.lock"
grep_ok "FAIL reported to feed" "$STATE/feed.log" "FAIL script incomplete"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; GFORTRAN_SHA256=""; magpie_require_pins' run_fn
ret_is "empty pin aborts" 1
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_require_pins' run_fn
ret_is "full pins pass" 0

# ============================================================
sec "disk guard (two tiers)"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_check_disk' run_fn STUB_DF_AVAIL_KB=1000000
ret_is "below ABORT blocks" 1
grep_ok "windows hint" "$STATE/screen.txt" "WINDOWS (C: drive)"
grep_ok "FAIL low disk fed" "$STATE/feed.log" "FAIL low disk"
nofile_ok "no install attempt" "$FAKE_HOME/.opencode"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_check_disk' run_fn STUB_DF_AVAIL_KB=10000000
ret_is "between ABORT and WARN continues" 0
grep_ok "warning on screen" "$STATE/screen.txt" "WARNING: only 9 GB"
grep_ok "WARNING fed" "$STATE/feed.log" "WARNING low disk"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_check_disk' run_fn STUB_DF_AVAIL_KB=200000000
ret_is "enough disk passes quietly" 0
grep_no "no warning" "$STATE/screen.txt" "WARNING"
# New tiers (full run included): abort below 9 GB, warn below 18 GB.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_check_disk' run_fn STUB_DF_AVAIL_KB=7000000
ret_is "6 GB free aborts under new tier" 1
grep_ok "FAIL low disk fed (new tier)" "$STATE/feed.log" "FAIL low disk"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_check_disk' run_fn STUB_DF_AVAIL_KB=16000000
ret_is "15 GB free warns under new tier" 0
grep_ok "warning at 15 GB" "$STATE/screen.txt" "WARNING: only 15 GB"
new_env
# Full entry on a writable HOME that aborts at the disk check: the
# entry legitimately owns the work dir, but ~/magpie belongs to the
# clone step ALONE (spec 5/6.8) - an abort before the clone must not
# have created it (the 555-HOME entry guard pins only the other case).
run_e2e STUB_DF_AVAIL_KB=1000000
ret_is "low disk aborts the whole run" 1
nofile_ok "abort before the clone never creates ~/magpie" "$FAKE_HOME/magpie"
# The probe TARGET is pinned on the source text: the df stub answers
# path-blind, so a probe regressing to a folder the entry no longer
# creates (old ~/magpie position) would read as "0 GB free" for every
# fresh student while all behavioural tests stayed green.
grep_ok "disk probe targets the work dir" "$SCRIPT" \
  'df -Pk "$MAGPIE_SETUP_DIR"'

# ============================================================
sec "root guard"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_setup_path' \
  run_fn STUB_ID_ROOT=1
ret_is "root run aborts" 1
grep_ok "root message" "$STATE/screen.txt" "do not run as root"
new_env
# Entry guard: ~/setup-magpie cannot be created (unwritable HOME) - the
# failure verdict is the only output, and it must still reach the
# screen although the log file is impossible here. ~/magpie is NOT
# created by the entry any more - the clone owns that folder.
chmod 555 "$FAKE_HOME"
run_e2e
chmod 700 "$FAKE_HOME"
ret_is "unwritable HOME aborts" 1
grep_ok "entry verdict names the failure" "$STATE/screen.txt" \
  "cannot create ~/setup-magpie"
nofile_ok "no work dir created" "$FAKE_HOME/setup-magpie"
nofile_ok "entry never touches ~/magpie" "$FAKE_HOME/magpie"

# ============================================================
sec "lock"
# ============================================================
new_env
mkdir -p "$FAKE_HOME/setup-magpie/.setup.lock"
sleep 60 &
LIVEPID=$!
echo "$LIVEPID" > "$FAKE_HOME/setup-magpie/.setup.lock/pid"
FN_BODY='magpie_take_lock' run_fn
kill "$LIVEPID" 2>/dev/null
ret_is "live lock exits 0" 0
grep_ok "heads-up line" "$STATE/screen.txt" "already running in another window"
cnt_is "single line" "already running" "$STATE/screen.txt" 1
file_ok "other lock untouched" "$FAKE_HOME/setup-magpie/.setup.lock/pid"
new_env
mkdir -p "$FAKE_HOME/setup-magpie/.setup.lock"
echo 999999 > "$FAKE_HOME/setup-magpie/.setup.lock/pid"
FN_BODY='magpie_take_lock' run_fn
ret_is "stale lock reclaimed silently" 0
# An early exit 0 inside take_lock (dead pid believed alive) skips any
# FN_BODY assertion - these observe from outside: no heads-up on the
# screen, and the reclaimed lock is gone with the sourcing shell
# (owner's EXIT cleanup ran).
grep_no "no already-running note on reclaim" "$STATE/screen.txt" \
  "already running"
nofile_ok "reclaimed lock released on exit" "$FAKE_HOME/setup-magpie/.setup.lock/pid"
# The second window must NOT clean the FIRST run's state: no deletion
# of its setup-dl-* downloads, no kill of its keep-alive.
new_env
mkdir -p "$FAKE_HOME/setup-magpie/.setup.lock"
sleep 60 &
LIVEPID=$!
echo "$LIVEPID" > "$FAKE_HOME/setup-magpie/.setup.lock/pid"
sleep 60 &
KPID=$!
echo "$KPID" > "$FAKE_HOME/setup-magpie/.keepalive.pid"
touch "$FAKE_HOME/setup-magpie/setup-dl-gams.exe"
FN_BODY='magpie_take_lock' run_fn
kill "$LIVEPID" 2>/dev/null
ret_is "second window exits 0 quietly" 0
file_ok "first run download untouched" "$FAKE_HOME/setup-magpie/setup-dl-gams.exe"
file_ok "first run keepalive pidfile untouched" "$FAKE_HOME/setup-magpie/.keepalive.pid"
if [ -n "$KPID" ] && kill -0 "$KPID" 2>/dev/null; then ok "first run keepalive not killed"; else no "first run keepalive not killed"; fi
kill "$KPID" 2>/dev/null

# ============================================================
sec "cold fail path (before MAGPIE_OS is set)"
# ============================================================
# The entry mkdir failure calls magpie_fail before magpie_main has
# set MAGPIE_OS - the feed detail's System line must still be filled.
new_env
EXPECT_SYS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f 2)
FN_BODY='magpie_sys_string' run_fn
ret_is "system string survives unset MAGPIE_OS" 0
grep_ok "system string reports the distro" "$FAKE_HOME/setup-magpie/setup-log.txt" "$EXPECT_SYS"

# ============================================================
sec "retry helper + pass-2 model"
# ============================================================
new_env
FN_BODY='flaky() { c="$STATE/f"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$c"; [ "$n" -gt 2 ]; }; magpie_retry 3 flaky' run_fn
ret_is "2 fails then success" 0
new_env
FN_BODY='alwaysfail() { return 1; }; magpie_retry 3 alwaysfail' run_fn
ret_is "persistent fail returns 1" 1
grep_ok "3 attempts logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "attempt 3/3"
new_env
make_tools
cat > "$STATE/pass2.sh" <<EOS
#!/bin/sh
unset MAGPIE_SOURCED MAGPIE_SELF
exec bash "$ENV/magpie.sh"
EOS
chmod 755 "$STATE/pass2.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_failed teststep' \
  run_fn "MAGPIE_SELF=$STATE/pass2.sh"
ret_is "pass 2 in a fresh process completes setup" 0
grep_ok "auto retry heads-up" "$STATE/screen.txt" "retrying automatically"
grep_ok "run finished fed" "$STATE/feed.log" "run finished"
# The same step failing in both passes (the real pass-2 shape: the pass-1
# step name arrives through the environment).
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP=teststep magpie_step_failed teststep' run_fn
ret_is "pass 2 failure blocks" 1
grep_ok "failure verdict after pass 2" "$STATE/screen.txt" "SETUP FAILED (twice, reproducible)"
grep_ok "failed step named" "$STATE/screen.txt" "SETUP FAILED (twice, reproducible): teststep"
grep_ok "code name in verdict" "$STATE/screen.txt" "code name: T1"
# "twice, reproducible" needs the SAME step in both passes: pass 1 died
# at the sandbox gate, pass 2 at something else. The TA still has to see
# that a retry pass happened, and after which step.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP=sandbox\ gate magpie_fail "full magpie run"' run_fn
ret_is "other step in pass 2 blocks" 1
grep_no "no twice claim for a different step" "$STATE/screen.txt" "twice, reproducible"
grep_ok "pass 2 names the pass-1 step" "$STATE/screen.txt" \
  "SETUP FAILED (pass 2, after: sandbox gate): full magpie run"
grep_ok "feed verdict carries the pass-1 step" "$STATE/feed.log" \
  "FAILED STEP (pass 2, after: sandbox gate): full magpie run"
# The same step again: the reproducible claim is earned.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP=sandbox\ gate magpie_fail "sandbox gate"' run_fn
ret_is "same step in pass 2 blocks" 1
grep_ok "twice claim for the same step" "$STATE/screen.txt" \
  "SETUP FAILED (twice, reproducible): sandbox gate"
# Pass 1 never claims a repetition, whatever the step.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
magpie_fail "sandbox gate"' run_fn
ret_is "pass 1 failure blocks" 1
grep_ok "pass 1 verdict is plain" "$STATE/screen.txt" "SETUP FAILED: sandbox gate"
# Pass 2 WITHOUT a recorded pass-1 step (an environment that never got the
# handover): says pass 2, names no other step, claims no repetition.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 magpie_fail "sandbox gate"' run_fn
ret_is "pass 2 without a pass-1 step blocks" 1
grep_ok "plain pass 2 verdict" "$STATE/screen.txt" "SETUP FAILED (pass 2): sandbox gate"
grep_no "no after-clause without a recorded step" "$STATE/screen.txt" "pass 2, after:"
grep_no "no twice claim without a recorded step" "$STATE/screen.txt" "twice, reproducible"
# The pass-1 step name must reach the re-executed pass 2 (that is what
# makes the verdict above decide).
new_env
make_tools
cat > "$STATE/pass2env.sh" <<'EOS'
#!/bin/sh
echo "PASS=$MAGPIE_PASS PASS1STEP=$MAGPIE_PASS1_STEP" > "$STATE/pass2_env.txt"
EOS
chmod 755 "$STATE/pass2env.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_failed "sandbox gate"' \
  run_fn "MAGPIE_SELF=$STATE/pass2env.sh"
file_ok "pass 2 re-exec recorded" "$STATE/pass2_env.txt"
grep_ok "pass 2 knows its pass-1 step" "$STATE/pass2_env.txt" \
  "PASS=2 PASS1STEP=sandbox gate"

# ============================================================
sec "sudo loop + keep-alive"
# ============================================================
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0 STUB_SUDO_V_FAILS=4
ret_is "sudo succeeds after 4 bad tries" 0
cnt_is "retry line 4x" "Password not accepted" "$STATE/screen.txt" 4
grep_no "no failure verdict" "$STATE/screen.txt" "SETUP FAILED"
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0 STUB_SUDO_V_FAILS=99
ret_is "sudo cap blocks" 1
grep_ok "failure verdict at cap" "$STATE/screen.txt" \
  "SETUP FAILED: password was never accepted"
cnt_is "6 rounds" "Password not accepted" "$STATE/screen.txt" 6
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=1
ret_is "warm timestamp no prompt" 0
grep_no "no prompt line" "$STATE/screen.txt" "asked now"
nofile_ok "keepalive only after ask" "$FAKE_HOME/setup-magpie/.keepalive.pid"
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_take_lock; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0
ret_is "prompt starts keepalive" 0
grep_ok "prompt line" "$STATE/screen.txt" "Type it blind"
wait_gone "$FAKE_HOME/setup-magpie/.keepalive.pid"
nofile_ok "owner exit stops keepalive + removes pidfile" "$FAKE_HOME/setup-magpie/.keepalive.pid"
# SIGKILL of the owner (no EXIT trap can run): the loop must watch the
# owner's own pid ($$), not $PPID - bash keeps $PPID at the OUTER parent
# inside a subshell, which would keep refreshing after the owner dies.
new_env
cat > "$STATE/keepstart.sh" <<EOS
#!/bin/bash
export HOME="$FAKE_HOME"
export PATH="$FAKE_BIN:$MINBIN"
export MAGPIE_KEEPALIVE_SECS=0.05
export MAGPIE_SOURCED=1 MAGPIE_SELF=""
. "$SRC"
mkdir -p "\$HOME/setup-magpie"
magpie_start_keepalive
wait
EOS
chmod 755 "$STATE/keepstart.sh"
bash "$STATE/keepstart.sh" >/dev/null 2>&1 &
KAOWNER=$!
wait_file "$FAKE_HOME/setup-magpie/.keepalive.pid"
KAPID=$(cat "$FAKE_HOME/setup-magpie/.keepalive.pid" 2>/dev/null || echo "")
sleep 0.25
kill -9 "$KAOWNER" 2>/dev/null
wait "$KAOWNER" 2>/dev/null
sleep 0.15
n1=$(cat "$STATE/sudo.log" 2>/dev/null | grep -c "sudo -n" || true)
n1=${n1:-0}
sleep 0.4
n2=$(cat "$STATE/sudo.log" 2>/dev/null | grep -c "sudo -n" || true)
n2=${n2:-0}
if [ "$n1" -ge 1 ] && [ "$n1" = "$n2" ]; then
  ok "SIGKILL owner stops the sudo refresher"
else
  no "SIGKILL owner stops the sudo refresher (grew $n1 -> $n2)"
  [ -n "$KAPID" ] && kill "$KAPID" 2>/dev/null
fi
# Two starts in one run must not stack refresher loops: the live pid
# in the pidfile short-circuits the second call (same pid kept, and
# the owner-exit cleanup then stops the ONE loop it knows about).
FN_BODY='MAGPIE_HANDLE=T1; magpie_take_lock; magpie_start_keepalive
p1=$(cat "$HOME/setup-magpie/.keepalive.pid")
magpie_start_keepalive
p2=$(cat "$HOME/setup-magpie/.keepalive.pid")
[ "$p1" = "$p2" ]' run_fn
ret_is "second start reuses live keep-alive" 0
nofile_ok "pidfile gone after owner exit" "$FAKE_HOME/setup-magpie/.keepalive.pid"
# keep-alive is killed BEFORE the sandbox gate runs:
new_env
make_tools
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_SELF=/bin/true
magpie_take_lock; magpie_sudo_warm; magpie_stop_keepalive; magpie_sandbox_gate' \
  run_fn STUB_SUDO_N_OK=0
ret_is "gate ran after sudo prompt" 0
grep_ok "keep-alive dead at gate instant" "$STATE/keepalive_at_gate.txt" "dead"
nofile_ok "keepalive pidfile gone" "$FAKE_HOME/setup-magpie/.keepalive.pid"
grep_ok "gate args: profile" "$STATE/nono.log" "--profile magpie-profile"
grep_ok "gate args: allow-cwd" "$STATE/nono.log" "--allow-cwd"
grep_ok "gate args: check-only child" "$STATE/nono.log" "--check-only"
grep_ok "gate args: env switch" "$STATE/nono.log" "MAGPIE_CHECK_ONLY=1"
grep_ok "gate args: madrat mainfolder passed" "$STATE/nono.log" "MADRAT_MAINFOLDER="
grep_ok "gate args: renv cache passed" "$STATE/nono.log" "RENV_PATHS_CACHE="
# The cached sudo credential is dropped with the refresher (no warm
# sudo may exist while sandboxed children run).
grep_ok "sudo cooled before the gate" "$STATE/sudo.log" "sudo -k"
grep_ok "no warm sudo at gate instant" "$STATE/sudo_at_gate.txt" "cool"
# The gate child's output stays OFF the screen: the parent printed the
# check block already, and nono's own chatter is student-noise too.
grep_no "gate child output off screen" "$STATE/screen.txt" "GATE-CHILD-OUTPUT-MARKER"
grep_ok "gate child output reaches log" "$FAKE_HOME/setup-magpie/setup-log.txt" "GATE-CHILD-OUTPUT-MARKER"
grep_no "nono's own banner off screen" "$STATE/screen.txt" "NONO-BANNER-MARKER"
grep_ok "nono's own banner reaches log" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "NONO-BANNER-MARKER"
# The log holds the child block ONCE (single append - no tee double
# write), and the parent owns the one student-facing gate line.
cnt_is "gate child logged once" "GATE-CHILD-OUTPUT-MARKER" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" 1
grep_ok "parent prints the gate OK line" "$STATE/screen.txt" \
  "OK: sandbox check passed"
# A failing gate child stays failing through the pipe (exit code of the
# sandboxed child, not of tee).
new_env
make_tools
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_SELF=/bin/true; magpie_take_lock; magpie_sandbox_gate' \
  run_fn STUB_NONO_GATE_EXIT=1 STUB_SUDO_N_OK=1
ret_is "gate exit code survives the log append" 1
# Early stop runs before the gate; it must be a harmless no-op when no
# keep-alive ever started and $HOME/setup-magpie is absent (no file
# created, exit 0). Custom subshell: run_fn always creates the dirs.
new_env
(
  base_env
  export MAGPIE_SOURCED=1 MAGPIE_SELF=""
  . "$SRC"
  magpie_stop_keepalive
) >> "$STATE/screen.txt" 2>&1
RET=$?
ret_is "stop is a no-op with no work dir" 0
nofile_ok "stop creates no work dir" "$FAKE_HOME/setup-magpie"

# ============================================================
sec "cache folders + rc lines"
# ============================================================
new_env
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_register_caches; magpie_register_caches' run_fn
ret_is "caches registered" 0
file_ok "madrat dir created" "$FAKE_HOME/.madrat"
file_ok "renv cache dir created" "$FAKE_HOME/.cache/R/renv"
# R user dirs (tools::R_user_dir): created so the sandboxed profile
# entries point at existing folders (gdtools font cache class).
file_ok "R data dir created" "$FAKE_HOME/.local/share/R"
file_ok "R cache dir created" "$FAKE_HOME/.cache/R"
file_ok "R config dir created" "$FAKE_HOME/.config/R"
cnt_is "MADRAT rc line deduped" "MADRAT_MAINFOLDER" "$FAKE_HOME/.bashrc" 1
cnt_is "RENV rc line deduped" "RENV_PATHS_CACHE" "$FAKE_HOME/.bashrc" 1
# A comment merely mentioning the variable must NOT suppress the export
# (old unanchored grep did) - and the real export line must appear.
new_env
printf '# discussed MADRAT_MAINFOLDER and RENV_PATHS_CACHE here\n' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_register_caches' run_fn
cnt_is "MADRAT export still written once" '^export MADRAT_MAINFOLDER=' "$FAKE_HOME/.bashrc" 1
cnt_is "RENV export still written once" '^export RENV_PATHS_CACHE=' "$FAKE_HOME/.bashrc" 1
# PATH lines: only real PATH entries count - a comment mentioning a
# longer path ("/usr/local/bin/foo") must not suppress the add, and
# already-present entries (own form or the tex installer's form) must
# not be appended twice.
new_env
printf '# see /usr/local/bin/foo for details\n' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_rc_add_path "$MAGPIE_RC" /usr/local/bin' run_fn
ret_is "comment mention does not suppress add" 0
cnt_is "PATH line added" '^export PATH="/usr/local/bin' "$FAKE_HOME/.bashrc" 1
new_env
printf 'export PATH="/usr/local/bin:$PATH"\n' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_rc_add_path "$MAGPIE_RC" /usr/local/bin' run_fn
ret_is "own PATH entry recognised (no add)" 1
cnt_is "still one PATH line" '^export PATH="/usr/local/bin' "$FAKE_HOME/.bashrc" 1
new_env
printf 'export PATH=$PATH:"/usr/local/bin"\n' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_rc_add_path "$MAGPIE_RC" /usr/local/bin' run_fn
ret_is "foreign installer PATH form recognised" 1
cnt_is "no second PATH line" 'usr/local/bin' "$FAKE_HOME/.bashrc" 1
# A commented-out export line is inert - it must not suppress the add.
new_env
printf '# export PATH="/usr/local/bin"\n' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_rc_add_path "$MAGPIE_RC" /usr/local/bin' run_fn
ret_is "commented-out export does not suppress add" 0
cnt_is "PATH line added despite comment" '^export PATH="/usr/local/bin' "$FAKE_HOME/.bashrc" 1
# An rc whose last line has no final newline must not swallow the new
# line (a merged line breaks both entries and reads as "already there").
new_env
printf 'export FOO=1' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_rc_add_path "$MAGPIE_RC" /usr/local/bin' run_fn
cnt_is "PATH line starts its own line" '^export PATH="/usr/local/bin' "$FAKE_HOME/.bashrc" 1
grep_ok "rc last line stays intact" "$FAKE_HOME/.bashrc" '^export FOO=1$'
new_env
printf 'export FOO=1' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_register_caches' run_fn
cnt_is "cache line starts its own line" '^export MADRAT_MAINFOLDER=' "$FAKE_HOME/.bashrc" 1
grep_ok "cache add keeps last line" "$FAKE_HOME/.bashrc" '^export FOO=1$'

# ============================================================
sec "TERM trap cleanup"
# ============================================================
new_env
(
  base_env
  export MAGPIE_SOURCED=1
  . "$SCRIPT"
  exec 4>/dev/null
  mkdir -p "$FAKE_HOME/setup-magpie"
  magpie_start_keepalive
  magpie_take_lock
  sleep 5 &
  wait $!
) 2>/dev/null &
tp=$!
wait_file "$FAKE_HOME/setup-magpie/.keepalive.pid"
wait_file "$FAKE_HOME/setup-magpie/.setup.lock/pid"
kp=$(cat "$FAKE_HOME/setup-magpie/.keepalive.pid" 2>/dev/null || echo "")
kill -TERM "$tp" 2>/dev/null
wait "$tp" 2>/dev/null
rc=$?
[ -n "$kp" ] && ok "keepalive was running" || no "keepalive was running"
[ "$rc" = 130 ] && ok "exit code 130 on TERM" || no "exit code 130 on TERM (got $rc)"
nofile_ok "lock removed" "$FAKE_HOME/setup-magpie/.setup.lock"
if [ -n "$kp" ] && kill -0 "$kp" 2>/dev/null; then no "keepalive killed"; else ok "keepalive killed"; fi

# ============================================================
sec "apt calls: dpkg lock timeout"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_apt_body' run_fn
ret_is "apt base body ok" 0
grep_ok "base update lock timeout" "$STATE/apt.log" "DPkg::Lock::Timeout=120 update"
grep_ok "base install lock timeout" "$STATE/apt.log" "DPkg::Lock::Timeout=120 install"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_apt_tools' \
  run_fn
ret_is "apt tools step ok" 0
grep_ok "tools update lock timeout" "$STATE/apt.log" "DPkg::Lock::Timeout=120 update"
grep_ok "tools install lock timeout" "$STATE/apt.log" "DPkg::Lock::Timeout=120 install"
# Ubuntu 26.04: libcurl4-*-dev are mutually conflicting (feed Lynx729)
# - the list must never request both flavours.
grep_no "no libcurl gnutls dev in list" "$STATE/apt.log" "libcurl4-gnutls-dev"
grep_no "healthy path no dist-upgrade" "$STATE/apt.log" "dist-upgrade"

# ============================================================
sec "apt tools: ubuntu floor, R age, -dev libs skip"
# ============================================================
# Ubuntu before 24.04 ships an R too old for magpie: fail up front.
new_env
printf 'ID=ubuntu\nVERSION_ID="22.04"\n' > "$ENV/os22"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; MAGPIE_PASS=2 magpie_step_apt_tools' \
  run_fn "MAGPIE_OS_RELEASE=$ENV/os22"
ret_is "ubuntu 22.04 blocked early" 1
grep_ok "floor message" "$STATE/screen.txt" "Ubuntu 22.04 ships an R older than 4.3"
grep_ok "wsl hint in verdict" "$STATE/screen.txt" "wsl --install -d Ubuntu-26.04"
grep_no "no apt call" "$STATE/apt.log" "apt-get"
# Other distros are not blocked by the ubuntu floor.
new_env
printf 'ID=debian\nVERSION_ID="13"\n' > "$ENV/osdeb"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_apt_tools' \
  run_fn "MAGPIE_OS_RELEASE=$ENV/osdeb"
ret_is "debian unaffected by ubuntu floor" 0
# An apt r-base that is still too old must fail the step, not print OK.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; MAGPIE_PASS=2 magpie_step_apt_tools' \
  run_fn STUB_R_OLD=1
ret_is "old R after install blocks step" 1
grep_no "no OK line with old R" "$STATE/screen.txt" "OK: R + support packages installed"
# The skip needs R + pandoc AND the -dev libraries: R+pandoc alone with
# a missing build library must run apt again.
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_apt_tools' \
  run_fn STUB_DPKG_MISSING=libgdal-dev
ret_is "missing -dev lib reruns apt step" 0
grep_ok "apt install ran" "$STATE/apt.log" "DPkg::Lock::Timeout=120 install"
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_apt_tools' run_fn
ret_is "all build libs present skips" 0
grep_no "skip when libs present" "$STATE/apt.log" "DPkg::Lock::Timeout=120 install"
grep_ok "skip logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "build libraries present"
# A half-configured library still answers dpkg -s (exit 0) - the guard
# must check the status line, not just the exit code.
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_apt_tools' \
  run_fn STUB_DPKG_HALF=libgdal-dev
ret_is "half-configured -dev lib reruns apt step" 0
grep_ok "half-configured reran the install" "$STATE/apt.log" "DPkg::Lock::Timeout=120 install"
grep_no "half-configured no skip log" "$FAKE_HOME/setup-magpie/setup-log.txt" "build libraries present"

# ============================================================
sec "apt tools: dist-upgrade escalation"
# ============================================================
# First bulk install fails (stale image deps) -> one dist-upgrade ->
# install retried inside the same attempt.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_apt_tools' \
  run_fn STUB_APT_INSTALL_FAILS=1
ret_is "apt tools recover after escalation" 0
grep_ok "escalation dist-upgrade runs" "$STATE/apt.log" "DPkg::Lock::Timeout=120 dist-upgrade"
cnt_is "install retried after escalation" " install -y" "$STATE/apt.log" 2
grep_ok "tools OK after escalation" "$STATE/screen.txt" "OK: R + support packages installed"
# Persistent fail: 3 attempts x (install + dist-upgrade + install),
# then pass-2 blocked with the failure verdict.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; MAGPIE_PASS=2 magpie_step_apt_tools' \
  run_fn STUB_APT_INSTALL_FAILS=99
ret_is "persistent apt fail blocks" 1
cnt_is "3 attempts x 2 installs" " install -y" "$STATE/apt.log" 6
cnt_is "3 escalations" " dist-upgrade" "$STATE/apt.log" 3
grep_ok "FAIL apt tools fed" "$STATE/feed.log" "FAIL apt course tools"
grep_no "no hint lines in verdict" "$STATE/screen.txt" "run this file again"

# ============================================================
sec "handle (code name)"
# ============================================================
new_env
FN_BODY='magpie_init_handle' run_fn
file_ok "handle file created" "$FAKE_HOME/setup-magpie/.magpie-course-handle"
h=$(cat "$FAKE_HOME/setup-magpie/.magpie-course-handle" 2>/dev/null)
case $h in
  [A-Z][a-z]*[0-9][0-9][0-9]) ok "handle format: Animal+3digits ($h)" ;;
  *) no "handle format: Animal+3digits ($h)" ;;
esac
grep_no "no user-facing box" "$STATE/screen.txt" "NOTE IT DOWN"
new_env
mkdir -p "$FAKE_HOME/setup-magpie"
echo "Fox123" > "$FAKE_HOME/setup-magpie/.magpie-course-handle"
FN_BODY='magpie_greet' run_fn
grep_ok "greet reuses handle (log)" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "reporting status as Fox123"
grep_no "no greet line on screen" "$STATE/screen.txt" "Fox123"
grep_no "no box on reuse" "$STATE/screen.txt" "NOTE IT DOWN"
# Present but EMPTY handle file (a sandboxed child with a stale profile
# can leave one): init must fall back to a FRESH name, never run under
# an empty one (the noclobber creation fails - the file exists - so the
# second read must not decide alone).
new_env
mkdir -p "$FAKE_HOME/setup-magpie"
: > "$FAKE_HOME/setup-magpie/.magpie-course-handle"
FN_BODY='magpie_greet' run_fn
ret_is "empty handle file heals" 0
grep_ok "empty handle gets a fresh name" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "reporting status as [A-Z][a-z]*[0-9][0-9][0-9]"
grep_no "never greets with an empty handle" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "reporting status as $"
# Present but UNREADABLE handle file (a stale-profile child may leave
# one it cannot even read): the same fresh-name healing, and the
# cat errors must stay suppressed - no "cat:" line may leak into the
# log the failure post quotes.
new_env
mkdir -p "$FAKE_HOME/setup-magpie"
echo "Fox123" > "$FAKE_HOME/setup-magpie/.magpie-course-handle"
chmod 000 "$FAKE_HOME/setup-magpie/.magpie-course-handle"
FN_BODY='magpie_greet' run_fn
ret_is "unreadable handle file heals" 0
grep_ok "unreadable handle gets a fresh name" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "reporting status as [A-Z][a-z]*[0-9][0-9][0-9]"
grep_no "no cat error leaks (unreadable handle)" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "cat:"
chmod 600 "$FAKE_HOME/setup-magpie/.magpie-course-handle" 2>/dev/null || true

# ============================================================
sec "config write"
# ============================================================
new_env
CFG="$FAKE_HOME/.config/opencode/opencode.json"
FN_BODY='magpie_write_opencode_config' run_fn
ret_is "writes fresh config" 0
grep_ok "model preselected" "$CFG" '"model": "hu/llm3"'
grep_no "course config carries no vLLM marker" "$CFG" "vLLM PIK HPC"
FN_BODY='magpie_write_opencode_config' run_fn
grep_ok "identical skip logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "already in place"
nofile_ok "no bak on skip" "$CFG.bak"
new_env
mkdir -p "$FAKE_HOME/.config/opencode"
echo '{"broken": true}' > "$FAKE_HOME/.config/opencode/opencode.json"
CFG="$FAKE_HOME/.config/opencode/opencode.json"
FN_BODY='magpie_write_opencode_config' run_fn
file_ok "foreign config backed up" "$CFG.bak"
grep_ok "foreign replaced" "$CFG" '"model": "hu/llm3"'
# vLLM PIK HPC guard: a dev/teacher config for the local vLLM endpoint
# is preserved untouched, no .bak, repair included (spec 6.2).
new_env
CFG="$FAKE_HOME/.config/opencode/opencode.json"
REF="$STATE/vllm-ref.json"
mkdir -p "$FAKE_HOME/.config/opencode"
printf '{\n  "provider": { "name": "vLLM PIK HPC" }\n}\n' > "$CFG"
cp "$CFG" "$REF"
FN_BODY='magpie_write_opencode_config' run_fn
ret_is "vLLM config run exits 0" 0
if cmp -s "$CFG" "$REF"; then ok "vLLM config byte-unchanged"; else no "vLLM config byte-unchanged"; fi
nofile_ok "no bak on vLLM guard" "$CFG.bak"
grep_ok "vLLM guard logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "vLLM PIK HPC config found"
new_env
CFG="$FAKE_HOME/.config/opencode/opencode.json"
REF="$STATE/vllm-ref.json"
mkdir -p "$FAKE_HOME/.config/opencode"
printf '{\n  "provider": { "name": "vLLM PIK HPC" }\n}\n' > "$CFG"
cp "$CFG" "$REF"
FN_BODY='magpie_write_opencode_config' run_fn MAGPIE_REPAIR=1
ret_is "vLLM config run exits 0 under repair" 0
if cmp -s "$CFG" "$REF"; then ok "repair never overrides vLLM guard"; else no "repair never overrides vLLM guard"; fi
nofile_ok "no bak on vLLM guard under repair" "$CFG.bak"

# ============================================================
sec "HU key rc line"
# ============================================================
new_env
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_register_hu_key' run_fn
ret_is "hu key registered" 0
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_register_hu_key' run_fn
cnt_is "rc line stays deduped" "HU_API_KEY" "$FAKE_HOME/.bashrc" 1
new_env
# A comment mentioning HU_API_KEY must not suppress the export.
printf '# TODO set HU_API_KEY later\n' > "$FAKE_HOME/.bashrc"
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_register_hu_key' run_fn
cnt_is "hu export written despite comment" '^export HU_API_KEY=' "$FAKE_HOME/.bashrc" 1

# ============================================================
sec "licence: placeholder / blank heredoc / pasted / replaces-demo / darwin"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_licence_available' run_fn
ret_is "placeholder detected" 1
grep_ok "warning on screen" "$STATE/screen.txt" "not embedded"
grep_ok "warning fed" "$STATE/feed.log" "WARNING gamslice not embedded"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "no gams folder -> rerun note" 1
grep_ok "rerun note fed" "$STATE/feed.log" "licence not written, no gams folder"
new_env
mkdir -p "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx"
T="$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
printf 'DEMO-SLICE-HANDS-OFF\n' > "$T"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "placeholder blocks the write" 1
grep_ok "demo gamslice untouched by placeholder run" "$T" "DEMO-SLICE-HANDS-OFF"
nofile_ok "no bak from a placeholder run" "$T.bak"
# Placeholder line deleted without a paste: blank heredoc = not
# embedded (must not write an empty licence file).
new_env
SRC="$ENV/magpie_lic_blank.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_licence_available' run_fn
ret_is "blank heredoc is not embedded" 1
grep_ok "blank heredoc warns" "$STATE/screen.txt" "not embedded"
new_env
SRC="$ENV/magpie_lic_blank.sh"
mkdir -p "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "blank heredoc blocks the write" 1
nofile_ok "no empty licence written" \
  "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
new_env
SRC="$ENV/magpie_lic.sh"
mkdir -p "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "pasted licence writes" 0
T="$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
grep_ok "licence content" "$T" "TEST-LICENCE-CONTENT"
mode_is "licence mode 600" "$T" 600
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
grep_ok "rerun: already in place" "$FAKE_HOME/setup-magpie/setup-log.txt" "already in place"
# The 2026-11 trap: the GAMS installer always ships a demo gamslice at
# this path, so existence must never skip the course licence - a
# DIFFERENT file is replaced and survives as .bak.
echo "OLD-DEMO-SLICE" > "$T"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "demo gamslice replaced by course licence" 0
grep_ok "course licence in place" "$T" "TEST-LICENCE-CONTENT"
grep_ok "old gamslice kept as bak" "$T.bak" "OLD-DEMO-SLICE"
grep_ok "replacement logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "replacing non-course gamslice.txt"
# The spec promises the replacement as a FEED line too: the TA reads
# the demo-license swap on the course feed, not just in a local log.
grep_ok "replacement fed" "$STATE/feed.log" "replaced non-course gamslice.txt"
mode_is "replaced licence mode 600" "$T" 600
new_env
SRC="$ENV/magpie_lic.sh"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "darwin licence writes" 0
T="$FAKE_HOME/Library/Application Support/GAMS/gamslice.txt"
grep_ok "darwin licence content" "$T" "TEST-LICENCE-CONTENT"
mode_is "darwin licence mode 600" "$T" 600
mode_is "darwin licence dir mode 700" "$(dirname "$T")" 700
# The resolved binary's banner drives the write (I10/I12 hardening).
# Demo banner + embedded gamslice: the gamslice lands in the resolved
# gams folder and the second probe (same binary) shows the course one.
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="$DEMO_BANNER"
ret_is "demo banner: course gamslice written" 0
grep_ok "gamslice in the resolved gams dir" "$FAKE_BIN/gamslice.txt" \
  "TEST-LICENCE-CONTENT"
mode_is "fresh gamslice mode 600" "$FAKE_BIN/gamslice.txt" 600
nofile_ok "no .bak for a fresh write" "$FAKE_BIN/gamslice.txt.bak"
grep_no "no replacement fed for a fresh write" "$STATE/feed.log" \
  "replaced non-course gamslice.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
grep_ok "re-probe PASSes as course licence" "$STATE/screen.txt" \
  "PASS gams (course licence found)"
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
printf 'OLD-DEMO-SLICE\n' > "$FAKE_BIN/gamslice.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="$DEMO_BANNER"
ret_is "demo banner with old gamslice: replaced with .bak" 0
grep_ok "course gamslice in place" "$FAKE_BIN/gamslice.txt" "TEST-LICENCE-CONTENT"
grep_ok "old gamslice kept as bak" "$FAKE_BIN/gamslice.txt.bak" "OLD-DEMO-SLICE"
grep_ok "replacement fed" "$STATE/feed.log" "replaced non-course gamslice.txt"
mode_is "replaced gamslice mode 600" "$FAKE_BIN/gamslice.txt" 600
# A foreign VALID licence stays untouched: no write, no .bak, and the
# check ladder PASSes it with the tell-the-TA note (a1).
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="GAMS 54.6.1 - Licensee: ACME Corp - the installed license is valid."
ret_is "foreign valid licence kept" 0
nofile_ok "no write over a foreign valid licence" "$FAKE_BIN/gamslice.txt"
nofile_ok "no .bak for a kept licence" "$FAKE_BIN/gamslice.txt.bak"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="GAMS 54.6.1 - Licensee: ACME Corp - the installed license is valid."
ret_is "a1: foreign valid licence PASSes with note" 0
grep_ok "a1 PASS note" "$STATE/screen.txt" \
  "PASS gams (licence not the course licence - tell the TA)"
# The real demo banner (Licensee + "license is valid" IN the demo
# wording): the demo/expired wording outranks both, so the course
# gamslice still goes in and the demo copy survives as .bak.
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
printf 'OLD-DEMO-SLICE\n' > "$FAKE_BIN/gamslice.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="$DEMO_BANNER"
ret_is "real demo banner replaces the demo licence" 0
grep_ok "course gamslice over a real demo banner" "$FAKE_BIN/gamslice.txt" \
  "TEST-LICENCE-CONTENT"
grep_ok "real demo gamslice kept as bak" "$FAKE_BIN/gamslice.txt.bak" \
  "OLD-DEMO-SLICE"
grep_ok "real demo replacement fed" "$STATE/feed.log" \
  "replaced non-course gamslice.txt"
# An expired licence (any owner) is not a valid one: replaced too.
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
printf 'OLD-FOREIGN-SLICE\n' > "$FAKE_BIN/gamslice.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="GAMS 54.6.1 - Licensee: ACME Corp - the installed license has expired"
ret_is "expired foreign licence replaced" 0
grep_ok "course gamslice over an expired licence" "$FAKE_BIN/gamslice.txt" \
  "TEST-LICENCE-CONTENT"
grep_ok "expired gamslice kept as bak" "$FAKE_BIN/gamslice.txt.bak" \
  "OLD-FOREIGN-SLICE"
grep_ok "expired replacement fed" "$STATE/feed.log" \
  "replaced non-course gamslice.txt"
# An EXPIRED course licence is broken too: the licensee name does not
# save it (same precedence as the check ladder).
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
printf 'OLD-COURSE-SLICE\n' > "$FAKE_BIN/gamslice.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="GAMS 54.6.1 - Licensee: Potsdam-Institut fuer Klimafolgenforschung - the installed license has expired"
ret_is "expired course licence replaced" 0
grep_ok "fresh course gamslice in place" "$FAKE_BIN/gamslice.txt" \
  "TEST-LICENCE-CONTENT"
grep_ok "expired course gamslice kept as bak" "$FAKE_BIN/gamslice.txt.bak" \
  "OLD-COURSE-SLICE"
# Unreadable banner (gams printed nothing) + a file that already IS the
# course gamslice: never rewritten - no .bak, no false replacement post.
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
cat > "$FAKE_BIN/gams" <<'EOS'
#!/bin/sh
exit 0
EOS
chmod 755 "$FAKE_BIN/gams"
printf 'TEST-LICENCE-CONTENT\n' > "$FAKE_BIN/gamslice.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "unreadable banner + course file in place: no rewrite" 0
grep_ok "in place despite an unreadable banner" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "course gamslice in place but gams banner unreadable"
nofile_ok "no .bak without a rewrite" "$FAKE_BIN/gamslice.txt.bak"
grep_no "no false replacement post" "$STATE/feed.log" \
  "replaced non-course gamslice.txt"
# "Root-owned" sysdir + symlinked gams: sudo writes beside the
# RESOLVED target folder (NOT the symlink's own folder); the student
# owns the result.
new_env
SRC="$ENV/magpie_lic.sh"
mkdir -p "$ENV/opt/gams" "$ENV/lic-tmp"
REAL=$(readlink -f "$ENV/opt/gams")
cp "$STATE/binlib/gams" "$ENV/opt/gams/gams"
printf 'OLD-DEMO-SLICE\n' > "$ENV/opt/gams/gamslice.txt"
chmod 555 "$ENV/opt/gams"
ln -sf "$ENV/opt/gams/gams" "$FAKE_BIN/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_SUDO_AS_ROOT=1 TMPDIR="$ENV/lic-tmp" \
  STUB_GAMS_BANNER="$DEMO_BANNER"
chmod 700 "$ENV/opt/gams"
ret_is "sudo path writes the unwritable resolved sysdir" 0
grep_ok "gamslice beside the resolved target" "$REAL/gamslice.txt" \
  "TEST-LICENCE-CONTENT"
grep_ok "old gamslice kept as bak" "$REAL/gamslice.txt.bak" "OLD-DEMO-SLICE"
nofile_ok "nothing beside the symlink" "$FAKE_BIN/gamslice.txt"
mode_is "sudo-written gamslice mode 600" "$REAL/gamslice.txt" 600
if [ "$(stat -c %U "$REAL/gamslice.txt")" = "$(id -un)" ]; then
  ok "gamslice owned by the student"
else
  no "gamslice owned by the student (owner $(stat -c %U "$REAL/gamslice.txt"))"
fi
grep_ok "sudo cp made the .bak" "$STATE/sudo.log" "sudo cp"
grep_ok "sudo tee wrote the gamslice" "$STATE/sudo.log" "sudo tee"
grep_ok "sudo chown hands it over" "$STATE/sudo.log" "sudo chown"
# The sudo path has no mv to hand the tmp file over: it must be removed
# (scenario TMPDIR holds only script temp files, all of them gone).
ls -A "$ENV/lic-tmp" > "$STATE/lic_tmp_left.txt" 2>/dev/null
cnt_is "sudo path leaves no tmp file" "" "$STATE/lic_tmp_left.txt" 0
# A written gamslice that gams still rejects (botched fill-in, wrong
# target): the honest FAIL - never "rerun this file".
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
cat > "$FAKE_BIN/gams" <<'EOS'
#!/bin/sh
printf '%s\n' 'Licensee: GAMS Demo, for EULA and demo limitations see G240131/0001CB-GEN' \
  'The installed license is valid.'
EOS
chmod 755 "$FAKE_BIN/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "rejected course gamslice FAILs" 1
grep_ok "rejected-by-gams message" "$STATE/screen.txt" \
  "course gamslice rejected by gams - tell the TA"
grep_no "rejected never claims a rerun" "$STATE/screen.txt" "rerun this file"
grep_ok "rejected fed" "$STATE/feed.log" "course gamslice rejected by gams"
# Same for a teacher licence that is already EXPIRED: naming the course
# licensee must not let it through the post-write verify.
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
cat > "$FAKE_BIN/gams" <<'EOS'
#!/bin/sh
printf '%s\n' 'Licensee: Potsdam-Institut fuer Klimafolgenforschung - the installed license has expired'
EOS
chmod 755 "$FAKE_BIN/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "expired course licence FAILs the verify probe" 1
grep_ok "expired verify message" "$STATE/screen.txt" \
  "course gamslice rejected by gams - tell the TA"
grep_ok "expired verify fed" "$STATE/feed.log" "course gamslice rejected by gams"
# macOS (I12): a framework gamslice is what GAMS reads first, so the
# framework folder owns the licence - even via sudo there.
new_env
SRC="$ENV/magpie_lic.sh"
FW="$ENV/Frameworks/GAMS.framework/Resources"
mkdir -p "$FW"
cp "$STATE/binlib/gams" "$FW/gams"
printf 'OLD-FW-SLICE\n' > "$FW/gamslice.txt"
chmod 555 "$FW"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn MAGPIE_GAMS_FRAMEWORK_DIR="$FW" STUB_SUDO_AS_ROOT=1 \
  STUB_GAMS_BANNER="$DEMO_BANNER"
chmod 700 "$FW"
ret_is "darwin: framework gamslice replaced via sudo" 0
grep_ok "course gamslice in the framework folder" "$FW/gamslice.txt" \
  "TEST-LICENCE-CONTENT"
grep_ok "framework gamslice kept as bak" "$FW/gamslice.txt.bak" "OLD-FW-SLICE"
mode_is "framework gamslice mode 600" "$FW/gamslice.txt" 600
grep_ok "sudo tee wrote the framework gamslice" "$STATE/sudo.log" "sudo tee"
nofile_ok "user data dir untouched" \
  "$FAKE_HOME/Library/Application Support/GAMS/gamslice.txt"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn MAGPIE_GAMS_FRAMEWORK_DIR="$FW"
grep_ok "darwin re-probe PASSes as course licence" "$STATE/screen.txt" \
  "PASS gams (course licence found)"
new_env
SRC="$ENV/magpie_lic.sh"
FW="$ENV/Frameworks/GAMS.framework/Resources"
mkdir -p "$FW"
cp "$STATE/binlib/gams" "$FW/gams"
printf 'FOREIGN-OWNED-SLICE\n' > "$FW/gamslice.txt"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn MAGPIE_GAMS_FRAMEWORK_DIR="$FW" \
  STUB_GAMS_BANNER="GAMS 54.6.1 - Licensee: ACME Corp - the installed license is valid."
ret_is "darwin: foreign framework gamslice kept" 0
grep_ok "framework gamslice untouched" "$FW/gamslice.txt" "FOREIGN-OWNED-SLICE"
nofile_ok "no .bak for a kept gamslice" "$FW/gamslice.txt.bak"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn MAGPIE_GAMS_FRAMEWORK_DIR="$FW" \
  STUB_GAMS_BANNER="GAMS 54.6.1 - Licensee: ACME Corp - the installed license is valid."
grep_ok "darwin a1 PASS note" "$STATE/screen.txt" \
  "PASS gams (licence not the course licence - tell the TA)"
# No framework gamslice: the user data dir stays the target (unchanged).
new_env
SRC="$ENV/magpie_lic.sh"
FW="$ENV/Frameworks/GAMS.framework/Resources"
mkdir -p "$FW"
cp "$STATE/binlib/gams" "$FW/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn MAGPIE_GAMS_FRAMEWORK_DIR="$FW" \
  STUB_GAMS_BANNER="*** Error: no license file found"
ret_is "darwin: no framework gamslice -> user data dir" 0
grep_ok "user data gamslice written" \
  "$FAKE_HOME/Library/Application Support/GAMS/gamslice.txt" \
  "TEST-LICENCE-CONTENT"
nofile_ok "no gamslice written into the framework" "$FW/gamslice.txt"
# No scratch dir for the licence probe either: the honest warning,
# gams never runs where the script stands, and nothing is written
# without a banner (the check ladder reports the real problem later).
# Only the probe's `mktemp -d` fails - the feed body file still works.
new_env
SRC="$ENV/magpie_lic.sh"
make_tools
cat > "$FAKE_BIN/mktemp" <<EOS
#!/bin/sh
case " \$* " in
  *" -d "*) exit 1 ;;
esac
exec "$MINBIN/mktemp" "\$@"
EOS
chmod 755 "$FAKE_BIN/mktemp"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="$DEMO_BANNER"
ret_is "licence step without a scratch dir returns honest" 1
grep_ok "licence temp folder warning on screen" "$STATE/screen.txt" \
  "licence probe needs a temp folder"
grep_ok "licence temp folder warning fed" "$STATE/feed.log" \
  "licence probe needs a temp folder"
nofile_ok "no blind write without a probe" "$FAKE_BIN/gamslice.txt"

# ============================================================
sec "checks table (gams banner + tools)"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "nothing installed -> FAIL" 1
grep_ok "gams not installed" "$STATE/screen.txt" "FAIL gams not installed"
grep_ok "Rscript missing line" "$STATE/screen.txt" "FAIL Rscript not found"
grep_ok "pandoc missing line" "$STATE/screen.txt" "FAIL pandoc not found"
grep_ok "tex missing line" "$STATE/screen.txt" "FAIL tex not found"
grep_no "no library line without marker" "$STATE/screen.txt" "R libraries"
grep_no "no full run line without marker" "$STATE/screen.txt" "full run"
grep_ok "check result fed" "$STATE/feed.log" "check result"
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "all stubs green -> PASS" 0
grep_ok "gams GAMS54 wording PASS" "$STATE/screen.txt" "PASS gams"
# Same machine with the plain (gamslice-less) script: the course
# licence is already installed, so the banner alone must PASS the
# gams check - rerunning an unfilled script may not break a good
# machine. (magpie.sh template = placeholder, unembedded.)
grep_ok "course licence PASS without embedding" "$STATE/screen.txt" \
  "PASS gams (course licence found)"
grep_no "no CONOPT note on screen" "$STATE/screen.txt" "CONOPT"
grep_ok "git PASS" "$STATE/screen.txt" "PASS git"
grep_ok "R PASS" "$STATE/screen.txt" "PASS R 4.4.2"
# Version probes run --vanilla (no .Rprofile/renv at startup), so a
# broken or not-yet-bootstrapped project cannot fail the R check.
grep_ok "R version probe uses --vanilla" "$STATE/rscript.log" \
  "--vanilla -e quit(status"
grep_ok "pandoc PASS" "$STATE/screen.txt" "PASS pandoc 3.1.0"
grep_ok "tex PASS" "$STATE/screen.txt" "PASS tex"
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="Licensee: MAgPIE course licence"
grep_ok "legacy licensee wording PASS" "$STATE/screen.txt" "PASS gams"
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="*** Error: no license file found"
ret_is "unlicensed banner FAIL" 1
grep_ok "licence missing line" "$STATE/screen.txt" "FAIL gams found but its licence file is missing"
# A truly empty banner (gams prints nothing) is unparseable too.
new_env
make_tools
cat > "$FAKE_BIN/gams" <<'EOS'
#!/bin/sh
EOS
chmod 755 "$FAKE_BIN/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "empty banner FAILs" 1
grep_ok "empty banner missing line" "$STATE/screen.txt" \
  "FAIL gams found but its licence file is missing"
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn STUB_R_OLD=1
ret_is "old R FAILs" 1
grep_ok "R version line" "$STATE/screen.txt" "FAIL R older than 4.3"
# Licence name check (licence embedded): the banner must show the
# course licensee; a foreign valid licence or the demo fallback FAIL.
new_env
make_tools
SRC="$ENV/magpie_lic.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "course licensee banner PASSes" 0
grep_ok "course licence PASS line" "$STATE/screen.txt" \
  "PASS gams (course licence found)"
new_env
make_tools
SRC="$ENV/magpie_lic.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="GAMS 54.6.1 - The installed license is valid."
ret_is "a1: foreign valid licence PASSes with note" 0
grep_ok "a1 PASS note" "$STATE/screen.txt" \
  "PASS gams (licence not the course licence - tell the TA)"
new_env
make_tools
SRC="$ENV/magpie_lic.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="$DEMO_BANNER"
ret_is "demo banner FAILs (embedded)" 1
grep_ok "demo licence FAIL line" "$STATE/screen.txt" \
  "FAIL gams runs only with the free demo licence"
# Plan chain: name check comes first, so the (unreal) mixed banner
# below PASSes; reordering the chain must trip this pin.
new_env
make_tools
SRC="$ENV/magpie_lic.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="Licensee: Potsdam-Institut (demo license)"
ret_is "name check wins over demo" 0
grep_ok "named PASS despite demo word" "$STATE/screen.txt" \
  "PASS gams (course licence found)"
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="$DEMO_BANNER"
ret_is "demo banner FAILs (placeholder licence too)" 1
grep_ok "demo FAIL line (placeholder)" "$STATE/screen.txt" \
  "FAIL gams runs only with the free demo licence"
# Without an embedded gamslice, naming the licensee is NOT enough: a
# demo gamslice registered with the institute name (banner shows both)
# must never pose as the course licence. With an embedded gamslice the
# name outranks the demo word (scenario above) - without one it must not.
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_GAMS_BANNER="Licensee: Potsdam-Institut (demo license)"
ret_is "licensee+demo without embedding FAILs" 1
grep_ok "poseur demo FAIL line" "$STATE/screen.txt" \
  "FAIL gams runs only with the free demo licence"
grep_no "poseur never PASSes as course licence" "$STATE/screen.txt" \
  "PASS gams (course licence found)"
new_env
make_tools
SRC="$ENV/magpie_lic.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; MAGPIE_COURSE_LICENSEE=; magpie_run_checks' run_fn
grep_ok "empty licensee falls back to weak check" "$STATE/screen.txt" \
  "PASS gams (license found)"
grep_no "no CONOPT note in the weak PASS" "$STATE/screen.txt" "CONOPT"
# The gams probe temp folder is removed after the checks.
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
if [ -z "$(ls -A "$ENV/tmp" 2>/dev/null)" ]; then
  ok "probe temp dir cleaned"
else
  no "probe temp dir cleaned"
fi
# No scratch dir (mktemp fails): gams must NOT be run where the setup
# script happens to stand - GAMS writes its files into the work folder.
new_env
make_tools
cat > "$FAKE_BIN/gams" <<'EOS'
#!/bin/sh
printf '%s\n' "$PWD" > "$STATE/gams_probe_cwd.txt"
printf '%s\n' "GAMS 54.6.1 - Licensee: Potsdam-Institut fuer Klimafolgenforschung"
EOS
cat > "$FAKE_BIN/mktemp" <<'EOS'
#!/bin/sh
exit 1
EOS
chmod 755 "$FAKE_BIN/gams" "$FAKE_BIN/mktemp"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "checks still decide without a scratch dir" 1
nofile_ok "gams never runs outside a scratch dir" "$STATE/gams_probe_cwd.txt"
grep_ok "no temp folder FAIL line" "$STATE/screen.txt" \
  "FAIL gams licence check needs a temp folder"

# ============================================================
sec "check-only child (sandbox side, no nono)"
# ============================================================
new_env
(
  base_env
  MAGPIE_CHECK_ONLY=1 bash "$ENV/magpie.sh" --check-only > "$STATE/screen.txt" 2>&1
)
RET=$?
ret_is "child fails without tools" 1
grep_ok "sandbox label fed" "$STATE/feed.log" "sandbox check result"
grep_ok "result lines on screen" "$STATE/screen.txt" "code name: "
grep_ok "check lines printed" "$STATE/screen.txt" "FAIL gams"
nofile_ok "no lock in child" "$FAKE_HOME/setup-magpie/.setup.lock"
nofile_ok "no log tee in child" "$FAKE_HOME/setup-magpie/setup-log.txt"
# Spec 5/6.7: the child creates (and sweeps) NOTHING - not even the
# work dir, which is deliberately invisible to the sandbox anyway.
nofile_ok "child creates no work dir" "$FAKE_HOME/setup-magpie"
nofile_ok "no opencode install in child" "$FAKE_HOME/.opencode"
grep_no "no archive download in child" "$STATE/curl.log" "registry.npmjs.org"
new_env
make_tools
(
  base_env
  MAGPIE_CHECK_ONLY=1 bash "$ENV/magpie.sh" --check-only > "$STATE/screen.txt" 2>&1
)
RET=$?
ret_is "child exits 0 when checks pass" 0
grep_ok "PASS lines in child screen" "$STATE/screen.txt" "PASS gams"
new_env
make_tools
mkdir -p "$FAKE_HOME/setup-magpie"
printf 'output/default_2026-01-01_00.00.00\n' \
  > "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
# Simulated sandbox: the work dir completely unreadable is what the
# gate child really sees (the profile deliberately stays outside it,
# spec 6.7) even though a full-run marker exists. The child must stay
# green AND stay silent about the full run: an invisible marker reads
# as "no marker", which is never a check result, let alone a FAIL.
chmod 000 "$FAKE_HOME/setup-magpie"
(
  base_env
  MAGPIE_CHECK_ONLY=1 bash "$ENV/magpie.sh" --check-only > "$STATE/screen.txt" 2>&1
)
RET=$?
chmod 700 "$FAKE_HOME/setup-magpie"
ret_is "child green with unreadable full-run marker" 0
grep_no "child marker check stays silent" "$STATE/screen.txt" "full run"

# ============================================================
sec "TinyTeX step: skip only with real tex, half dir heals"
# ============================================================
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
mkdir -p "$FAKE_HOME/.TinyTeX/share"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_tinytex' \
  run_fn
ret_is "half TinyTeX dir reinstall heals" 0
grep_ok "half dir logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "incomplete"
grep_ok "install_tinytex ran" "$STATE/rscript.log" "install_tinytex"
nofile_ok "stale share gone" "$FAKE_HOME/.TinyTeX/share"
file_ok "tex binary exists" "$FAKE_HOME/.TinyTeX/bin/x86_64-unknown-linux-gnu/tex"
grep_ok "rc texbin line" "$FAKE_HOME/.bashrc" ".TinyTeX/bin"
new_env
mkdir -p "$FAKE_HOME/.TinyTeX/bin/x86_64-unknown-linux-gnu"
printf '#!/bin/sh\necho tex\n' > "$FAKE_HOME/.TinyTeX/bin/x86_64-unknown-linux-gnu/tex"
chmod 755 "$FAKE_HOME/.TinyTeX/bin/x86_64-unknown-linux-gnu/tex"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_tinytex' \
  run_fn
ret_is "complete TinyTeX dir skips install" 0
grep_no "no R calls" "$STATE/rscript.log" "install_tinytex"
grep_no "no heads-up" "$STATE/screen.txt" "installing TinyTeX"
grep_ok "rc texbin line (skip)" "$FAKE_HOME/.bashrc" ".TinyTeX/bin"
# macOS: tinytex installs to ~/Library/TinyTeX - an incomplete one
# must heal, a complete one must be found (skip + rc registration).
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
mkdir -p "$FAKE_HOME/Library/TinyTeX/share"
mkdir -p "$FAKE_HOME/.TinyTeX/share"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_tinytex' \
  run_fn "STUB_TINYTEX_ROOT=$FAKE_HOME/Library/TinyTeX"
ret_is "darwin half Library/TinyTeX heals" 0
grep_ok "install_tinytex ran (darwin)" "$STATE/rscript.log" "install_tinytex"
nofile_ok "stale share gone (darwin)" "$FAKE_HOME/Library/TinyTeX/share"
nofile_ok "stale .TinyTeX gone too (darwin)" "$FAKE_HOME/.TinyTeX/share"
file_ok "tex in Library/TinyTeX" "$FAKE_HOME/Library/TinyTeX/bin/x86_64-unknown-linux-gnu/tex"
grep_ok "rc texbin line (darwin)" "$FAKE_HOME/.zshrc" "Library/TinyTeX"
new_env
mkdir -p "$FAKE_HOME/Library/TinyTeX/bin/universal-darwin"
printf '#!/bin/sh\necho tex\n' > "$FAKE_HOME/Library/TinyTeX/bin/universal-darwin/tex"
chmod 755 "$FAKE_HOME/Library/TinyTeX/bin/universal-darwin/tex"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_tinytex' \
  run_fn
ret_is "complete Library/TinyTeX skips install" 0
grep_no "no R calls (darwin skip)" "$STATE/rscript.log" "install_tinytex"
grep_ok "rc texbin line (darwin skip)" "$FAKE_HOME/.zshrc" "Library/TinyTeX/bin/universal-darwin"
# The 2026-11 course failure: a machine carried a tinytex so old it
# fetched the dead yihui.org/TinyTeX-1.tgz. The body must refresh the
# package first (unsilenced!) and refuse to run a pre-0.46 installer.
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_tinytex_body' \
  run_fn
ret_is "gate pass: refresh then install succeeds" 0
head -n 1 "$STATE/rscript.log" > "$STATE/call1"
tail -n 1 "$STATE/rscript.log" > "$STATE/call2"
grep_ok "install.packages runs before the gate" "$STATE/call1" "install.packages"
grep_ok "gate + install_tinytex run second" "$STATE/call2" "install_tinytex"
grep_ok "install chatter reaches the log (no silencing)" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "STUB-INSTALL-PACKAGES-MARKER"
file_ok "tex installed (gate pass)" "$FAKE_HOME/.TinyTeX/bin/x86_64-unknown-linux-gnu/tex"
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_tinytex_body' \
  run_fn STUB_TINYTEX_VERSION=0.36
ret_is "gate 0.36 fails the body (drives retries)" 1
nofile_ok "no tex below the 0.46 floor" "$FAKE_HOME/.TinyTeX"
# Same stale tinytex through the step: retries hit the cap, the pass-2
# failure verdict text is the one every other step uses.
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="TinyTeX install" magpie_step_tinytex' \
  run_fn STUB_TINYTEX_VERSION=0.36
ret_is "gate failure fails the step at the cap" 1
grep_ok "step failure verdict" "$STATE/screen.txt" \
  "SETUP FAILED (twice, reproducible): TinyTeX install"
cnt_is "stale gate retried to the cap" "install.packages" "$STATE/rscript.log" 3
grep_ok "retried install chatter reaches the log" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "STUB-INSTALL-PACKAGES-MARKER"
# The Rscript stub mirrors the gate's CONTRACT, it cannot execute the
# R snippet itself - so the gate's floor constant is pinned on the
# source text (same idiom as the curl policy pins): a silently lowered
# gate re-arms the dead-downloader bug on real machines, red here.
grep_ok "gate floor 0.46 pinned on the source" "$SCRIPT" \
  'packageVersion("tinytex") < "0.46"'

# ============================================================
sec "nono profile: pull + magpie-profile build"
# ============================================================
new_env
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_pull_nono_profile' run_fn
ret_is "pack pulled at pin" 0
grep_ok "pull carries the pin" "$STATE/nono.log" "pull nolabs-ai/opencode@9.9.9"
grep_ok "pack pinned" "$STATE/nono.log" "nono pin nolabs-ai/opencode"
# The registry hands back a stale pack despite the pinned ref: the
# post-pull version check must catch it and fail the step at the cap.
new_env
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="nono profile pull" magpie_pull_nono_profile' \
  run_fn STUB_NONO_PULL_WRONG_VER=8.8.8
ret_is "wrong pack version fails" 1
grep_ok "wrong version logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "nono pack wrong version after pull: got 8.8.8, want 9.9.9"
grep_ok "pull step failure verdict" "$STATE/screen.txt" \
  "SETUP FAILED (twice, reproducible): nono profile pull"
new_env
put_nono
# Read entries are gated on folder existence (validation rejects
# missing paths) - give the fake machine the folders to see them.
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
mkdir -p "$HOME/gams" "$HOME/.TinyTeX"
magpie_step_magpie_profile' run_fn
ret_is "profile built" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
file_ok "profile file exists" "$PJSON"
grep_ok "extends pack profile" "$PJSON" '"extends": \["nolabs-ai/opencode"\]'
grep_ok "linux read list holds gams" "$PJSON" "$FAKE_HOME/gams"
grep_ok "linux read list holds TinyTeX" "$PJSON" "$FAKE_HOME/.TinyTeX"
grep_no "no read_file without MAGPIE_SELF" "$PJSON" "read_file"
grep_ok "validate called" "$STATE/nono.log" "profile validate"
# The gate child re-executes the script inside the sandbox: with
# MAGPIE_SELF known, that exact file must be listed readable.
new_env
put_nono
mkdir -p "$FAKE_HOME/gams" "$FAKE_HOME/R-home/library" "$FAKE_HOME/R-site-lib" \
  "$FAKE_HOME/etc-R"
# Debian layout: the files inside the R home's etc/ are symlinks out
# of the tree (/usr/lib/R/etc/Renviron -> /etc/R/Renviron) - the
# target folder needs its own read entry, Landlock does not follow
# links from the R home grant. R itself resolves it (stubbed here).
cat > "$FAKE_BIN/Rscript" <<'EOS'
#!/bin/sh
case "$*" in
  *normalizePath*) echo "$HOME/etc-R" ;;
  *) echo "$HOME/R-home"; echo "$HOME/R-home/library"; echo "$HOME/R-site-lib" ;;
esac
EOS
chmod 755 "$FAKE_BIN/Rscript"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
: > "$HOME/setup-magpie.sh"
mkdir -p "$HOME/setup-magpie"
: > "$HOME/setup-magpie/.magpie-course-handle"
MAGPIE_SELF="$HOME/setup-magpie.sh"
magpie_step_magpie_profile' run_fn
ret_is "profile with script file builds" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "read_file lists the script" "$PJSON" \
  '"path": "'"$FAKE_HOME"'/setup-magpie.sh"'
grep_ok "read_file lists the handle file" "$PJSON" \
  '"path": "'"$FAKE_HOME"'/setup-magpie/.magpie-course-handle"'
grep_ok "write section after read_file intact" "$PJSON" '"write"'
# The 2026-11 gate death: apt R (Renviron, libraries) was invisible in
# the sandbox -> "cannot find system Renviron" -> FAIL R. R.home and
# every .libPaths entry go into the read list; children of R.home
# (base library) dedupe against it.
grep_ok "read holds the R home" "$PJSON" '"'"$FAKE_HOME"'/R-home"'
grep_ok "read holds the site library" "$PJSON" '"'"$FAKE_HOME"'/R-site-lib"'
grep_ok "read holds the symlinked etc target" "$PJSON" '"'"$FAKE_HOME"'/etc-R"'
grep_no "base library deduped under R home" "$PJSON" "R-home/library"
# Toolchain trees for source builds (start.R compiles dozens of C/
# Fortran packages; the /usr/bin gcc drivers posix_spawn cc1/collect2
# from trees outside nono's system groups). The constants are readable
# by the harness, so the entry list does not depend on the host's
# compiler layout.
new_env
put_nono
mkdir -p "$FAKE_HOME/fakecc1" "$FAKE_HOME/fakecollect" "$FAKE_HOME/fakeinc" \
  "$FAKE_HOME/fakedpkg"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_TOOLCHAIN_DIRS="$HOME/fakecc1 $HOME/fakecollect $HOME/fakeinc"
MAGPIE_DPKG_DIRS="$HOME/fakedpkg"
magpie_step_magpie_profile' run_fn
ret_is "profile with toolchain dirs builds" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "read holds the cc1 tree" "$PJSON" "$FAKE_HOME/fakecc1"
grep_ok "read holds the collect2 tree" "$PJSON" "$FAKE_HOME/fakecollect"
grep_ok "read holds the include tree" "$PJSON" "$FAKE_HOME/fakeinc"
grep_ok "read holds the dpkg status folder" "$PJSON" "$FAKE_HOME/fakedpkg"
new_env
put_nono
mkdir -p "$FAKE_HOME/fakecc1"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_TOOLCHAIN_DIRS="$HOME/fakecc1 $HOME/missing-tree"
magpie_step_magpie_profile' run_fn
ret_is "missing toolchain dir skipped" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "present toolchain dir listed" "$PJSON" "$FAKE_HOME/fakecc1"
grep_no "absent toolchain dir omitted" "$PJSON" "missing-tree"
new_env
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
magpie_register_caches; magpie_step_magpie_profile' run_fn
ret_is "linux profile has cache write paths" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
# Scoped read-block extract: the same quoted path also lands in WRITE
# (the user dirs are write entries too), so a whole-file grep can never
# prove a READ grant - it passes on the write entry alone.
sed -n '/"read": \[/,/\]/p' "$PJSON" > "$STATE/read-block.txt"
grep_ok "write section present" "$PJSON" '"write"'
grep_ok "write holds madrat" "$PJSON" "$FAKE_HOME/.madrat"
grep_ok "write holds renv cache" "$PJSON" ".cache/R/renv"
grep_ok "read holds madrat too" "$STATE/read-block.txt" "$FAKE_HOME/.madrat"
# R user dirs: literal write entries (registered before the build),
# gated read entries (the folders exist after registration).
grep_ok "write holds the R cache dir" "$PJSON" \
  '"'"$FAKE_HOME"'/.cache/R"'
grep_ok "write holds the R data dir" "$PJSON" \
  '"'"$FAKE_HOME"'/.local/share/R"'
grep_ok "write holds the R config dir" "$PJSON" \
  '"'"$FAKE_HOME"'/.config/R"'
grep_ok "read holds the R cache dir" "$STATE/read-block.txt" \
  '"'"$FAKE_HOME"'/.cache/R"'
grep_ok "read holds the R data dir" "$STATE/read-block.txt" \
  '"'"$FAKE_HOME"'/.local/share/R"'
grep_ok "read holds the R config dir" "$STATE/read-block.txt" \
  '"'"$FAKE_HOME"'/.config/R"'
# The 2026-11 course failure: apt texlive satisfied the TinyTeX step,
# so ~/.TinyTeX never existed - the read list must simply omit it and
# the build must pass, not reference a folder validation rejects.
new_env
put_nono
mkdir -p "$FAKE_HOME/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "profile builds with missing ~/.TinyTeX" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "gams entry present (no-tinytex case)" "$PJSON" "$FAKE_HOME/gams"
grep_no "tinytex entry omitted when folder absent" "$PJSON" 'TinyTeX"'
grep_ok "cache read entries stay literal" "$PJSON" "$FAKE_HOME/.madrat"
new_env
put_nono
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
MAGPIE_GFORTRAN_DIR="$HOME/gfortran"
MAGPIE_GFORTRAN_DIR_NEW="$HOME/opt-gfortran"
MAGPIE_TOOLCHAIN_DIRS_DARWIN="$HOME/fakeclt"
mkdir -p "$HOME/gfortran" "$HOME/opt-gfortran" "$HOME/.TinyTeX" \
  "$HOME/Library/TinyTeX" "$HOME/Library/Application Support/GAMS" "$HOME/fakeclt"
magpie_register_caches; magpie_step_magpie_profile' run_fn
ret_is "darwin profile built" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "darwin keeps gams framework read" "$PJSON" "/Library/Frameworks/GAMS.framework"
grep_ok "darwin reads clang toolchain dir" "$PJSON" "$FAKE_HOME/fakeclt"
grep_ok "darwin write holds R user dirs" "$PJSON" "org.R-project.R"
sed -n '/"read": \[/,/\]/p' "$PJSON" > "$STATE/read-block.txt"
grep_ok "darwin reads the R data dir" "$STATE/read-block.txt" \
  '"'"$FAKE_HOME"'/Library/Application Support/org.R-project.R"'
# Both gfortran trees, each listed only when it exists: /opt/gfortran is
# what the 12.2- AND 14.2-universal pkgs install into (a modern R's FC and
# its f951 live there), /usr/local/gfortran is the 6.x-era legacy tree.
grep_ok "darwin reads gfortran dir" "$PJSON" "$FAKE_HOME/gfortran"
grep_ok "darwin reads the modern gfortran tree" "$STATE/read-block.txt" \
  '"'"$FAKE_HOME"'/opt-gfortran"'
grep_ok "darwin reads Library/TinyTeX" "$PJSON" "$FAKE_HOME/Library/TinyTeX"
grep_ok "darwin reads .TinyTeX too" "$PJSON" "$FAKE_HOME/.TinyTeX"
grep_ok "darwin reads licence folder" "$PJSON" "Application Support/GAMS"
grep_no "darwin omits R.framework when absent" "$PJSON" "R.framework"
grep_ok "darwin write section present" "$PJSON" '"write"'
grep_ok "darwin write holds madrat" "$PJSON" "$FAKE_HOME/.madrat"
grep_ok "darwin write holds renv cache" "$PJSON" ".cache/R/renv"
# Only one of the two gfortran trees exists: the other stays out (the
# validator rejects a policy path missing on disk).
new_env
put_nono
mkdir -p "$FAKE_HOME/opt-gfortran"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
MAGPIE_GFORTRAN_DIR="$HOME/legacy-gfortran"
MAGPIE_GFORTRAN_DIR_NEW="$HOME/opt-gfortran"
magpie_step_magpie_profile' run_fn
ret_is "darwin profile with one gfortran tree" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "present gfortran tree listed" "$PJSON" '"'"$FAKE_HOME"'/opt-gfortran"'
grep_no "absent gfortran tree omitted" "$PJSON" "legacy-gfortran"
# Bare macOS machine (no TinyTeX/licence/pkg folders yet): only the
# guaranteed entries may appear in the policy.
new_env
put_nono
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
MAGPIE_GFORTRAN_DIR="$HOME/no-legacy-gfortran"
MAGPIE_GFORTRAN_DIR_NEW="$HOME/no-opt-gfortran"
magpie_step_magpie_profile' run_fn
ret_is "darwin profile without optional dirs" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "gams framework entry is literal" "$PJSON" "/Library/Frameworks/GAMS.framework"
grep_no "no gfortran entry without folder" "$PJSON" "gfortran"
grep_no "no tinytex entry without folders" "$PJSON" 'TinyTeX"'
grep_no "no licence entry without folder" "$PJSON" "Application Support/GAMS"
# The framework entry FOLLOWS MAGPIE_GAMS_FRAMEWORK_DIR (it used to be a
# second, hard-coded copy of the default path).
new_env
put_nono
FWROOT="$ENV/Fw/GAMS.framework"
mkdir -p "$FWROOT/Resources"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
MAGPIE_GAMS_FRAMEWORK_DIR="$ENV/Fw/GAMS.framework/Resources"
magpie_step_magpie_profile' run_fn
ret_is "darwin profile with an overridden framework dir" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "framework root follows the override" "$PJSON" "\"$FWROOT\""
grep_no "no hard-coded framework root left" "$PJSON" "/Library/Frameworks/GAMS.framework"
# A gams binary sitting directly IN that framework root (not under
# Resources): the derived root entry and the resolved-sysdir entry are
# the same folder - it may be granted only once.
new_env
put_nono
FWROOT="$ENV/Fw2/GAMS.framework"
mkdir -p "$FWROOT/Resources"
cp "$STATE/binlib/gams" "$FWROOT/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
MAGPIE_GAMS_FRAMEWORK_DIR="$ENV/Fw2/GAMS.framework/Resources"
PATH="$ENV/Fw2/GAMS.framework:$PATH"
magpie_step_magpie_profile' run_fn
ret_is "darwin profile with gams in the framework root" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
cnt_is "framework root granted once" "\"$FWROOT\"," "$PJSON" 1
# A GAMS whose PATH entry is a SYMLINK (macOS layouts do this too): the
# real binary's folder is what needs granting and what the run PATH
# carries. Relative and absolute link, each to its OWN real folder - the
# answers must differ, or the second grep could ride on the first line.
new_env
put_nono
mkdir -p "$ENV/optreal/gams" "$ENV/optreal2/gams" "$ENV/linkbin" "$ENV/linkbin2"
cp "$STATE/binlib/gams" "$ENV/optreal/gams/gams"
cp "$STATE/binlib/gams" "$ENV/optreal2/gams/gams"
ln -sf ../optreal/gams/gams "$ENV/linkbin/gams"
ln -sf "$ENV/optreal2/gams/gams" "$ENV/linkbin2/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; PATH="$ENV/linkbin:$PATH"
magpie_gams_sysdir' run_fn
grep_ok "relative link resolves to the real folder" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "$ENV/optreal/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; PATH="$ENV/linkbin2:$PATH"
magpie_gams_sysdir' run_fn
grep_ok "absolute link resolves to the real folder" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "$ENV/optreal2/gams"
new_env
put_nono
make_tools
mkdir -p "$ENV/optreal/gams" "$ENV/linkbin"
cp "$STATE/binlib/gams" "$ENV/optreal/gams/gams"
ln -sf ../optreal/gams/gams "$ENV/linkbin/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
PATH="$ENV/linkbin:$PATH"
mkdir -p "$HOME/magpie" "$HOME/setup-magpie"
magpie_step_magpie_profile; magpie_step_full_run' run_fn
ret_is "symlinked gams: profile + full run" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "symlinked gams: real folder granted" "$PJSON" "\"$ENV/optreal/gams\""
grep_no "symlinked gams: link folder not granted" "$PJSON" "\"$ENV/linkbin\""
grep_ok "symlinked gams: run PATH uses the real folder" "$STATE/nono.log" \
  "PATH=$ENV/optreal/gams"
# GAMS installed under $HOME on macOS: the folder is granted like the
# TinyTeX tree under ~ - only $HOME itself never is.
new_env
put_nono
mkdir -p "$FAKE_HOME/Applications/GAMS54"
cp "$STATE/binlib/gams" "$FAKE_HOME/Applications/GAMS54/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
PATH="$HOME/Applications/GAMS54:$PATH"
magpie_step_magpie_profile' run_fn
ret_is "darwin profile with GAMS under home" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "home GAMS folder granted" "$PJSON" "\"$FAKE_HOME/Applications/GAMS54\""
if grep -qE "^ *\"$FAKE_HOME\",$" "$PJSON"; then
  no "HOME itself never granted [got: $FAKE_HOME as an entry]"
else
  ok "HOME itself never granted"
fi
# Same machine, licence dir = GAMS data dir: one entry, not two.
new_env
put_nono
mkdir -p "$FAKE_HOME/Library/Application Support/GAMS"
cp "$STATE/binlib/gams" "$FAKE_HOME/Library/Application Support/GAMS/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
PATH="$HOME/Library/Application Support/GAMS:$PATH"
magpie_step_magpie_profile' run_fn
ret_is "darwin profile with GAMS in the data dir" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
cnt_is "GAMS data dir listed once" "\"$FAKE_HOME/Library/Application Support/GAMS\"," \
  "$PJSON" 1
# A gams binary sitting DIRECTLY in $HOME (PATH holds ~ itself): the
# resolved sysdir IS $HOME - never grantable, subtree rule or not.
new_env
put_nono
cp "$STATE/binlib/gams" "$FAKE_HOME/gams"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1
PATH="$HOME:$PATH"
magpie_step_magpie_profile' run_fn
ret_is "darwin profile with gams directly in HOME" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_no "HOME itself not granted (gams in HOME)" "$PJSON" "\"$FAKE_HOME\","
new_env
mkdir -p "$FAKE_HOME/.config/nono/profiles"
echo "changed by student" > "$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "modified profile kept" 0
grep_ok "modified file untouched" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" "changed by student"
# A profile written by an OLDER script version (our description marker,
# old content) is regenerated; the stale copy survives as .bak.
new_env
mkdir -p "$FAKE_HOME/.config/nono/profiles"
cat > "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" <<'OFP'
{
  "meta": {
    "name": "magpie-profile",
    "description": "MAgPIE course: opencode + GAMS + R + TinyTeX"
  },
  "extends": ["opencode"],
  "filesystem": {
    "read": ["/stale/old/path"]
  }
}
OFP
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "stale generated profile regenerated" 0
grep_ok "regenerated content current" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" "(setup v12)"
grep_ok "stale copy kept as bak" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json.bak" "/stale/old/path"
grep_ok "regeneration logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "regenerated"
# Rerun right after regeneration: content is current now, so the cmp
# branch reports "already in place" - no second regeneration.
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "rerun after regen: profile current" 0
grep_ok "rerun: already in place logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "already in place"
cnt_is "regenerated exactly once over two runs" "regenerated" "$FAKE_HOME/setup-magpie/setup-log.txt" 1
# A hand-edited copy of our template keeps the marker: still
# regenerated (documented tradeoff) - the edit survives in .bak.
new_env
mkdir -p "$FAKE_HOME/.config/nono/profiles"
cat > "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" <<'OFP'
{
  "meta": {
    "name": "magpie-profile",
    "description": "MAgPIE course: opencode + GAMS + R + TinyTeX (setup v2)"
  },
  "extends": ["opencode"],
  "filesystem": {
    "read": ["/student/added/path"]
  }
}
OFP
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "marker-stamped edit regenerated" 0
grep_ok "edit kept in bak" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json.bak" "/student/added/path"
# GAMS outside ~/gams (PATH install): licence + sandbox read entry.
new_env
put_nono
cp "$STATE/binlib/gams" "$FAKE_BIN/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
mkdir -p "$HOME/gams"
magpie_step_magpie_profile' run_fn
ret_is "profile with PATH-gams builds" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "profile reads the PATH-gams folder" "$PJSON" "$FAKE_BIN"
grep_ok "extra entry comma-terminated" "$PJSON" "${FAKE_BIN}\","
grep_ok "profile still reads ~/gams" "$PJSON" "$FAKE_HOME/gams"
new_env
SRC="$ENV/magpie_lic.sh"
cp "$STATE/binlib/gams" "$FAKE_BIN/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_licence_dir' run_fn
grep_ok "licence dir follows PATH-gams" "$FAKE_HOME/setup-magpie/setup-log.txt" "$FAKE_BIN"
# Symlinked PATH gams: the sandbox reads the REAL folder (readlink -f
# resolution), and the marker shows the current schema.
new_env
put_nono
mkdir -p "$ENV/opt/gams"
REAL=$(readlink -f "$ENV/opt/gams")
cp "$STATE/binlib/gams" "$ENV/opt/gams/gams"
ln -sf "$ENV/opt/gams/gams" "$FAKE_BIN/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
magpie_step_magpie_profile' run_fn
ret_is "profile with symlinked PATH-gams builds" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "profile reads the resolved sysdir" "$PJSON" "$REAL"
grep_ok "schema marker current" "$PJSON" "(setup v12)"
# Linux mirror of the darwin rule: a stray gams DIRECTLY in $HOME
# must never make the profile readable at $HOME itself.
new_env
put_nono
cp "$STATE/binlib/gams" "$FAKE_HOME/gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
PATH="$HOME:$PATH"
magpie_step_magpie_profile' run_fn
ret_is "linux profile with gams directly in HOME" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_no "HOME itself not granted (linux, gams in HOME)" "$PJSON" "\"$FAKE_HOME\","
new_env
make_tools
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
magpie_step_magpie_profile' run_fn STUB_NONO_VALIDATE_EXIT=1 \
  STUB_NONO_VALIDATE_ERR="path /home/x/.TinyTeX does not exist"
ret_is "validate failure blocks (2 passes)" 1
grep_ok "profile step named in verdict" "$STATE/screen.txt" \
  "SETUP FAILED (twice, reproducible): magpie-profile build"
# Whoever reads the feed must see WHY, not just "failed validation" -
# the real nono message is logged and the rejected candidate follows as
# ONE line: nothing is written to a side file any more, and a multi-line
# dump would push the diagnostics out of the 25 log lines that the
# failure post carries.
grep_ok "validator complaint logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "failed validation: path /home/x/.TinyTeX does not exist"
grep_ok "rejected candidate logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "rejected candidate: { \"meta\""
nofile_ok "no candidate side file" "$FAKE_HOME/magpie/setup-help-profile.json"
new_env
make_installed
sed -i 's|"version":"9.9.9"|"version":"8.8.8"|' "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_pull_nono_profile' run_fn
ret_is "drift force re-pulls" 0
grep_ok "force pull at pin" "$STATE/nono.log" "pull force=1 ref=nolabs-ai/opencode@9.9.9"

# ============================================================
sec "9P relocation: Windows-drive copies move, native ones stay"
# ============================================================
# The stub answers the only stat -f call site (magpie_native_self_copy):
# anything under /mnt is a WSL Windows mount, the fake home is ext4.
stat_stub() {
  cat > "$FAKE_BIN/stat" <<'EOS'
#!/bin/sh
case "$*" in
  *"/mnt/"*) echo v9fs ;;
  *) echo ext4 ;;
esac
exit 0
EOS
  chmod 755 "$FAKE_BIN/stat"
}
new_env
stat_stub
DL="$FAKE_HOME/mnt/c/Users/Max Mustermann/Downloads"
mkdir -p "$DL"
printf 'MAGPIE-9P-ORIGINAL\n' > "$DL/setup-magpie.sh"
# Real Downloads files sit world-readable on the 9P mount, and a fresh
# login shell has umask 022: the relocated copy of the (teacher-filled:
# feed credentials + licence) script must still land private.
chmod 644 "$DL/setup-magpie.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; umask 022
MAGPIE_SELF="'"$DL"'/setup-magpie.sh"
magpie_native_self_copy
printf "%s\n" "$MAGPIE_SELF" > "$STATE/self.txt"' run_fn
ret_is "9P script relocates (exit 0)" 0
NATIVE="$FAKE_HOME/setup-magpie/self/setup-magpie.sh"
grep_ok "self redirected to native copy" "$STATE/self.txt" \
  "setup-magpie/self/setup-magpie.sh"
grep_ok "copy carries the content" "$NATIVE" "MAGPIE-9P-ORIGINAL"
file_ok "Windows-drive original stays untouched" "$DL/setup-magpie.sh"
grep_ok "Windows drive note logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "Windows drive"
grep_no "Linux-side note off screen" "$STATE/screen.txt" "Linux-side copy"
# Private modes despite the 022 umask: the copy holds the filled script.
mode_is "native copy is 600" "$NATIVE" 600
mode_is "self folder is 700" "$FAKE_HOME/setup-magpie/self" 700
# Reruns from the relocated (native) path must not copy again.
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1
MAGPIE_SELF="'"$FAKE_HOME"'/setup-magpie/self/setup-magpie.sh"
magpie_native_self_copy
printf "%s\n" "$MAGPIE_SELF" > "$STATE/self.txt"' run_fn
ret_is "native script stays put (exit 0)" 0
grep_ok "self unchanged after native run" "$STATE/self.txt" \
  "^$FAKE_HOME/setup-magpie/self/setup-magpie.sh$"
cnt_is "no second relocation" "Windows drive" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" 1
# No stat at all (ancient systems): silent no-op, MAGPIE_SELF kept.
new_env
rm -f "$MINBIN/stat"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1
PATH="$MINBIN"
MAGPIE_SELF=/bin/sh
magpie_native_self_copy
printf "%s\n" "$MAGPIE_SELF" > "$STATE/self.txt"' run_fn
ret_is "missing stat tolerated (exit 0)" 0
grep_ok "self kept without stat" "$STATE/self.txt" "^/bin/sh$"
nofile_ok "no copy folder made" "$FAKE_HOME/setup-magpie/self"
# The copy destination cannot be created (setup-magpie/self taken by a
# file): the run must not die here, but it must not stay silent either -
# the log names the still-9P path state for whoever reads the feed tail.
new_env
stat_stub
DL="$FAKE_HOME/mnt/c/Users/Max Mustermann/Downloads"
mkdir -p "$DL"
printf 'MAGPIE-9P-ORIGINAL\n' > "$DL/setup-magpie.sh"
mkdir -p "$FAKE_HOME/setup-magpie"
printf 'occupied\n' > "$FAKE_HOME/setup-magpie/self"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1
MAGPIE_SELF="'"$DL"'/setup-magpie.sh"
magpie_native_self_copy
printf "%s\n" "$MAGPIE_SELF" > "$STATE/self.txt"' run_fn
ret_is "blocked relocation stays non-fatal (exit 0)" 0
grep_ok "self stays on the Windows path" "$STATE/self.txt" "mnt/c/Users"
grep_ok "failed copy is logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "9P relocation copy failed"
grep_no "failed copy note off screen" "$STATE/screen.txt" "9P"

# ============================================================
sec "macOS branches (forced MAGPIE_OS=darwin, stub installer)"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_os_base' \
  run_fn STUB_XCODE_SELECT=1
ret_is "CLT install branch ran" 0
grep_ok "softwareupdate newest label" "$STATE/sudo.log" "softwareupdate --install Command Line Tools for Xcode 16.2"
grep_ok "CLT heads-up" "$STATE/screen.txt" "Xcode Command Line Tools, about 5-20 min"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_os_base' run_fn
ret_is "CLT skip when present" 0
grep_no "no heads-up when skipped" "$STATE/screen.txt" "installing"
new_env
cp "$STATE/binlib/gfortran" "$FAKE_BIN/gfortran"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/no-legacy-gf" \
    MAGPIE_GFORTRAN_DIR_NEW="$FAKE_HOME/no-opt-gf"
ret_is "gfortran skip when present" 0
nofile_ok "no pkg download" "$STATE/curl.log"
grep_no "no installer call" "$STATE/installer.log" "installer"
# Nothing on the machine and no R to ask yet (this step runs BEFORE the
# R step): the fallback probes decide, and the single pinned 14.2 pkg is
# what gets downloaded - both probe dirs are pinned to absent fake dirs so
# no scenario depends on the host's /opt or /usr/local.
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/no-legacy-gf" \
    MAGPIE_GFORTRAN_DIR_NEW="$FAKE_HOME/no-opt-gf"
ret_is "gfortran pkg installs" 0
grep_ok "14.2 pkg is the one downloaded" "$STATE/curl.log" "gfortran-14.2-universal.pkg"
grep_ok "attempt logs pkg + FC target" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "gfortran install attempt: gfortran-14.2-universal.pkg, FC target $FAKE_HOME/no-opt-gf/bin"
grep_ok "installer -pkg called" "$STATE/installer.log" "installer -pkg"
grep_ok "gfortran pkg name" "$STATE/installer.log" "setup-dl-gfortran.pkg"
grep_ok "installer via sudo" "$STATE/sudo.log" "sudo installer -pkg"
grep_ok "OK line" "$STATE/screen.txt" "OK: gfortran installed"
file_ok "gfortran now on PATH" "$FAKE_BIN/gfortran"
nofile_ok "setup-dl pkg removed" "$FAKE_HOME/setup-magpie/setup-dl-gfortran.pkg"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1
MAGPIE_PKG_URL=$GFORTRAN_URL; MAGPIE_PKG_SHA=$GFORTRAN_SHA256; magpie_gfortran_body' \
  run_fn STUB_BAD_ARCHIVE=1
ret_is "gfortran checksum mismatch blocks" 1
nofile_ok "installer never called" "$STATE/installer.log"
nofile_ok "no sudo before verify" "$STATE/sudo.log"
nofile_ok "no pkg left behind" "$FAKE_HOME/setup-magpie/setup-dl-gfortran.pkg"
# The 2026-11 Pangolin317 loop, machine-checked: detection asks R (R CMD
# config FC), it never guesses an install dir. An FC that resolves to an
# executable IS the present verdict - and that bin dir is what the rc
# must gain, or the compiles and sandboxed children still find nothing.
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
mkdir -p "$FAKE_HOME/opt-gf/bin"
cp "$STATE/binlib/gfortran" "$FAKE_HOME/opt-gf/bin/gfortran"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR_NEW="$FAKE_HOME/opt-gf" \
    STUB_FC_PATH="$FAKE_HOME/opt-gf/bin/gfortran"
ret_is "r fc resolves - step skips" 0
nofile_ok "no pkg download (fc present)" "$STATE/curl.log"
grep_ok "present verdict logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "gfortran: present"
grep_ok "rc gains the FC bin dir" "$FAKE_HOME/.zshrc" "$FAKE_HOME/opt-gf/bin"
grep_ok "gfortran registered log" "$FAKE_HOME/setup-magpie/setup-log.txt" "gfortran registered"
# The Rscript stub IS R here - it mirrors the snippet's contract but
# cannot execute it. The snippet's three mechanisms are the design
# contract itself, so pin them on the source text (curl-policy idiom):
# first-token extraction (flag-suffixed FC), the executability gate
# (the 2026-11 loop was a folder that merely EXISTS counting as
# present) and bare-name resolution through Sys.which.
grep_ok "FC first-token extraction pinned" "$SCRIPT" 'p <- w\[1\]'
grep_ok "FC executable gate pinned" "$SCRIPT" 'file.access(p, 1) == 0'
grep_ok "FC bare-name resolution pinned" "$SCRIPT" 'Sys.which(p)'
# Installer success alone must never read as present: R is there, its FC
# is not, so the step keeps the retry model and fails - after having
# downloaded exactly the one pinned pkg.
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/no-legacy-gf" \
    MAGPIE_GFORTRAN_DIR_NEW="$FAKE_HOME/no-opt-gf"
ret_is "fc unresolved - step fails after the retries" 1
grep_ok "14.2 pkg url (fc unresolved)" "$STATE/curl.log" "gfortran-14.2-universal.pkg"
grep_ok "installer ran (fc unresolved)" "$STATE/installer.log" "installer -pkg"
grep_ok "step failed verdict logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "step failed after retries: gfortran install"
# What the feed's 25-line tail must show instead of three identical
# `installer:` stanzas: FC plus a one-line listing of BOTH pkg targets.
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
mkdir -p "$FAKE_HOME/legacy-gf/bin"
cp "$STATE/binlib/gfortran" "$FAKE_HOME/legacy-gf/bin/gfortran-6"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1
MAGPIE_PKG_URL=$GFORTRAN_URL; MAGPIE_PKG_SHA=$GFORTRAN_SHA256
MAGPIE_GFORTRAN_DIR="$HOME/legacy-gf"; MAGPIE_GFORTRAN_DIR_NEW="$HOME/opt-gf"
magpie_gfortran_body' \
  run_fn STUB_GF_TARGET="$FAKE_HOME/opt-gf/bin"
ret_is "installed but fc unresolved fails the body" 1
grep_ok "fc diagnostic line" "$FAKE_HOME/setup-magpie/setup-log.txt" "no usable FC: fc= |"
grep_ok "diagnostic lists the new pkg tree" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "new $FAKE_HOME/opt-gf/bin: (gfortran"
grep_ok "diagnostic lists the legacy tree" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "legacy $FAKE_HOME/legacy-gf/bin: (gfortran-6"
# Off-PATH pkg target: the dir must land in rc + this run's PATH, or
# renv compiles fail and sandboxed children never see gfortran.
# No R yet here, so the pkg-target probe decides.
new_env
mkdir -p "$FAKE_HOME/opt-gf/bin"
cp "$STATE/binlib/gfortran" "$FAKE_HOME/opt-gf/bin/gfortran"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/no-legacy-gf" \
    MAGPIE_GFORTRAN_DIR_NEW="$FAKE_HOME/opt-gf"
ret_is "gfortran off-PATH present skips + registers" 0
nofile_ok "no pkg download" "$STATE/curl.log"
grep_ok "rc gfortran dir line" "$FAKE_HOME/.zshrc" "$FAKE_HOME/opt-gf/bin"
grep_ok "gfortran registered log" "$FAKE_HOME/setup-magpie/setup-log.txt" "gfortran registered"
# The legacy 6.x-era tree (/usr/local/gfortran, what this script never
# installs): a usable gfortran is a usable gfortran - skip, register
# THAT dir.
new_env
mkdir -p "$FAKE_HOME/legacy-gf/bin"
cp "$STATE/binlib/gfortran" "$FAKE_HOME/legacy-gf/bin/gfortran"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/legacy-gf" \
    MAGPIE_GFORTRAN_DIR_NEW="$FAKE_HOME/no-opt-gf"
ret_is "legacy gfortran tree skips + registers its dir" 0
nofile_ok "no pkg download (legacy tree)" "$STATE/curl.log"
grep_ok "rc legacy gfortran dir line" "$FAKE_HOME/.zshrc" "$FAKE_HOME/legacy-gf/bin"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/no-legacy-gf" \
    MAGPIE_GFORTRAN_DIR_NEW="$FAKE_HOME/opt-gf" STUB_GF_TARGET="$FAKE_HOME/opt-gf/bin"
ret_is "gfortran pkg install registers off-PATH dir" 0
grep_ok "installer -pkg called" "$STATE/installer.log" "installer -pkg"
grep_ok "OK: gfortran installed" "$STATE/screen.txt" "OK: gfortran installed"
grep_ok "rc gfortran dir line (install)" "$FAKE_HOME/.zshrc" "$FAKE_HOME/opt-gf/bin"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_r' run_fn
ret_is "R pkg installs" 0
grep_ok "R pkg name" "$STATE/installer.log" "setup-dl-R.pkg"
grep_ok "OK: R installed" "$STATE/screen.txt" "OK: R installed"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_pandoc' run_fn
ret_is "pandoc pkg installs" 0
grep_ok "pandoc pkg name" "$STATE/installer.log" "setup-dl-pandoc.pkg"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_install_pkg gams "$GAMS_URL_DARWIN_ARM64" "$GAMS_SHA256_DARWIN_ARM64"' run_fn
ret_is "gams pkg download + sudo installer" 0
grep_ok "gams pkg passed to installer" "$STATE/installer.log" "setup-dl-gams.pkg"
grep_ok "installer target root" "$STATE/installer.log" "-target /"
nofile_ok "gams pkg file removed" "$FAKE_HOME/setup-magpie/setup-dl-gams.pkg"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_install_pkg gams "$GAMS_URL_DARWIN_ARM64" "$GAMS_SHA256_DARWIN_ARM64"' \
  run_fn STUB_BAD_ARCHIVE=1
ret_is "gams pkg checksum blocks" 1
nofile_ok "installer not reached" "$STATE/installer.log"
nofile_ok "no sudo before verify" "$STATE/sudo.log"

# ============================================================
sec "GAMS linux install via fake self-extractor"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_install_gams; magpie_register_gams' run_fn
ret_is "gams self-extract install" 0
file_ok "gams binary extracted" "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gams"
grep_ok "OK line" "$STATE/screen.txt" "OK: GAMS 54.6.1 installed"
grep_ok "gams install fed" "$STATE/feed.log" "gams 54.6.1 installed"
grep_ok "gams dir in rc" "$FAKE_HOME/.bashrc" "gams54.6.1_linux_x64_64_sfx"
nofile_ok "exe removed after extract" "$FAKE_HOME/setup-magpie/setup-dl-gams.exe"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_install_gams' \
  run_fn STUB_BAD_GAMS=1
ret_is "gams corrupt download blocks" 1
grep_ok "gams step named" "$STATE/screen.txt" "SETUP FAILED (twice, reproducible): GAMS install"
# With several installs the pinned version's folder wins for finding.
new_env
mkdir -p "$FAKE_HOME/gams/gams47.6.0_linux_x64_64_sfx" \
  "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx"
FN_BODY='MAGPIE_OS=linux; magpie_find_gams_dir' run_fn
grep_ok "pinned version folder preferred" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "gams54.6.1_linux_x64_64_sfx"
# A reinstall removes the pinned folder only - other versions stay.
new_env
mkdir -p "$FAKE_HOME/gams/gams47.6.0_linux_x64_64_sfx" \
  "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx"
touch "$FAKE_HOME/gams/gams47.6.0_linux_x64_64_sfx/KEEPME"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_gams_body_linux' run_fn
ret_is "reinstall extract ok" 0
file_ok "other version folder untouched" "$FAKE_HOME/gams/gams47.6.0_linux_x64_64_sfx/KEEPME"
file_ok "pinned folder re-extracted" "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gams"
# A root-owned GAMS folder (outside ~/gams): the sudo path is tried;
# a sudo that cannot write (no knob) ends honest - no crash, no gamslice.
new_env
SRC="$ENV/magpie_lic.sh"
mkdir -p "$ENV/ro-gams"
cp "$STATE/binlib/gams" "$ENV/ro-gams/gams"
chmod 555 "$ENV/ro-gams"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; PATH="$ENV/ro-gams:$PATH"; magpie_install_licence' \
  run_fn STUB_GAMS_BANNER="$DEMO_BANNER"
ret_is "unwritable gams dir: failed sudo write FAILs" 1
grep_ok "sudo attempt on screen" "$STATE/screen.txt" "is not writable even with sudo"
grep_ok "not writable fed" "$STATE/feed.log" "licence dir not writable"
grep_ok "sudo tee attempted" "$STATE/sudo.log" "sudo tee"
nofile_ok "no gamslice written into the unwritable dir" "$ENV/ro-gams/gamslice.txt"
chmod 755 "$ENV/ro-gams"

# ============================================================
sec "download temp-file guard"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; mkdir -p "$HOME/setup-magpie"
cp "$STATE/archives/cli-$OC_TARGET-9.9.9.tgz" "$HOME/setup-magpie/dl.tgz"
magpie_download "http://x/cli-$OC_TARGET-9.9.9.tgz" "$HOME/setup-magpie/dl.tgz" "$OC_SHA"' run_fn
ret_is "intact temp file skips re-download" 0
grep_no "no request for the asset" "$STATE/curl.log" "cli-"
file_ok "temp file kept for the caller" "$FAKE_HOME/setup-magpie/dl.tgz"
new_env
FN_BODY='MAGPIE_OS=linux; mkdir -p "$HOME/setup-magpie"
echo partial > "$HOME/setup-magpie/dl.tgz"
magpie_download "http://x/dl.tgz" "$HOME/setup-magpie/dl.tgz" deadbeef' run_fn STUB_CURL_DL_FAILS=1
ret_is "failed download removes the temp file" 1
nofile_ok "no temp left to wedge a resume" "$FAKE_HOME/setup-magpie/dl.tgz"
# The download policy promised in the spec (flag list, stall guard,
# resume) is pinned on the source text - a quiet flag drop would keep
# every behavioural test green while course downloads lose their retry
# and timeout behaviour.
grep_ok "curl policy: retry flags" "$SCRIPT" \
  "curl -sS -fL --retry 4 --retry-delay 5 --retry-all-errors"
grep_ok "curl policy: stall guard" "$SCRIPT" \
  "--connect-timeout 15 --max-time 900"
grep_ok "curl policy: resumed fetches" "$SCRIPT" \
  "magpie_curl -C - -o"

# ============================================================
sec "magpie clone guards"
# ============================================================
# Both course scripts share ~/magpie, so both specs pin the own-file
# allowlist as the SAME list in the two scripts - neither script may
# block the other's clone. Compare the guards verbatim (comments aside).
magpie_guard_list() {
  sed -n '/case \$entry in/,/esac/p' "$1" | grep -v '^ *#'
}
# Non-empty first: an extraction that quietly matched nothing (both
# sides "") would make the comparison trivially true.
if [ -n "$(magpie_guard_list "$SCRIPT")" ] \
  && [ "$(magpie_guard_list "$SCRIPT")" \
  = "$(magpie_guard_list "$HERE/../magpie-opencode.sh")" ]; then
  ok "clone guard lists identical in both course scripts"
else
  no "clone guard lists identical in both course scripts"
fi
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
echo "mine" > "$FAKE_HOME/magpie/important.txt"
run_e2e
ret_is "foreign dir blocks" 1
grep_ok "foreign dir message" "$STATE/screen.txt" "not a magpie clone"
new_env
# The guard's allowlist, pinned directly: every name an old layout could
# leave in ~/magpie (own logs, markers, install leftovers) must let the
# clone through. In a real entry run the legacy sweep moves or drops
# most of these BEFORE the guard runs - the allowlist stays as the
# second line for leftovers the sweep could not remove, and it is the
# only code deciding tolerance, so exercise it as a unit (magpie_clone_-
# magpie straight, sweep bypassed). setup-help-profile.json is the
# profile-rejection dump the 2026-11 distributed copies left behind -
# exactly on the machines whose clone never ran (the profile step sits
# BEFORE the clone).
FN_BODY='mkdir -p "$HOME/magpie/opencode-extract" "$HOME/magpie/nono-extract"
echo "log" > "$HOME/magpie/setup-log.txt"
echo "help" > "$HOME/magpie/setup-help.txt"
echo "{}" > "$HOME/magpie/setup-help-profile.json"
touch "$HOME/magpie/opencode-dl.tgz" "$HOME/magpie/nono-dl.tar.gz"
touch "$HOME/magpie/setup-dl-crashed.pkg"
printf "2026-01-01 00:00:00\nnono 0.81.0\nopencode 2.2.7\n" \
  > "$HOME/magpie/.setup-finished"
printf "output/default_2026-01-01_00.00.00\n" > "$HOME/magpie/.setup-fullrun-ok"
magpie_clone_magpie' run_fn
ret_is "own files only -> guard proceeds" 0
file_ok "clone recreated .git" "$FAKE_HOME/magpie/.git"
grep_ok "clone happened" "$STATE/screen.txt" "OK: magpie downloaded"
grep_no "no false foreign-dir abort" "$STATE/screen.txt" "not a magpie clone"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
# Legacy layout markers still sitting in ~/magpie: the entry sweep
# moves them into the work dir before any step runs, so the guard sees
# a bare folder, the clone proceeds - and the FULL RUN then fails on
# the (migrated, stale) marker instead of re-running.
printf '2026-01-01 00:00:00\nnono 0.81.0\nopencode 2.2.7\n' \
  > "$FAKE_HOME/magpie/.setup-finished"
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
run_e2e
ret_is "legacy markers migrated, run fails on stale marker" 1
grep_no "no false foreign-dir abort" "$STATE/screen.txt" "not a magpie clone"
file_ok "clone recreated .git" "$FAKE_HOME/magpie/.git"
grep_ok "clone happened" "$STATE/screen.txt" "OK: magpie downloaded"
grep_ok "stale marker FAIL line" "$STATE/screen.txt" "FAIL full run artifacts missing - rerun this file"
grep_ok "finished marker moved to work dir" \
  "$FAKE_HOME/setup-magpie/.setup-finished" "nono 0.81.0"
nofile_ok "old finished marker gone" "$FAKE_HOME/magpie/.setup-finished"
nofile_ok "old fullrun marker gone" "$FAKE_HOME/magpie/.setup-fullrun-ok"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
git -C "$FAKE_HOME/magpie" init -q
git -C "$FAKE_HOME/magpie" remote add origin "file://$STATE/origin.git"
run_e2e
ret_is "interrupted clone healed on rerun" 0
grep_ok "heal logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "interrupted clone found"
grep_ok "clone checked out file" "$FAKE_HOME/magpie/README.md" "readme"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
git -C "$FAKE_HOME/magpie" init -q
git -C "$FAKE_HOME/magpie" remote add origin https://elsewhere.invalid/repo.git
run_e2e
ret_is "foreign origin in .git blocks" 1
grep_ok "foreign dir message" "$STATE/screen.txt" "not a magpie clone"
# URL shape differences must not read as "not a magpie clone": the
# ssh form of the official repo, and a fork (same repo name, log note).
new_env
make_installed
git -C "$FAKE_HOME/magpie" remote set-url origin git@github.com:magpiemodel/magpie.git
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_clone_magpie' run_fn
ret_is "official repo via ssh url accepted" 0
grep_ok "url note logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "using the existing clone"
grep_no "no false not-a-clone" "$STATE/screen.txt" "not a magpie clone"
new_env
make_installed
git -C "$FAKE_HOME/magpie" remote set-url origin "file://$STATE/origin"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_clone_magpie' run_fn
ret_is "url without .git suffix accepted" 0
new_env
make_installed
git -C "$FAKE_HOME/magpie" remote set-url origin git@github.com:student/magpie.git
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_clone_magpie' \
  run_fn "MAGPIE_MAGPIE_URL=file://$STATE/magpie"
ret_is "same-name fork accepted with note" 0
grep_ok "fork url note" "$FAKE_HOME/setup-magpie/setup-log.txt" "origin is"
grep_no "no false not-a-clone (fork)" "$STATE/screen.txt" "not a magpie clone"
# A trailing slash is spelling, not another repo.
new_env
make_installed
git -C "$FAKE_HOME/magpie" remote set-url origin https://github.com/magpiemodel/magpie/
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_clone_magpie' run_fn
ret_is "official url with trailing slash accepted" 0
grep_no "no false not-a-clone (slash)" "$STATE/screen.txt" "not a magpie clone"
# A removed origin is own state: proceed, no bogus note, heal re-adds it.
new_env
make_installed
git -C "$FAKE_HOME/magpie" remote remove origin
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_clone_magpie' run_fn
ret_is "removed origin proceeds" 0
grep_no "no note for empty origin" "$FAKE_HOME/setup-magpie/setup-log.txt" "origin is"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
git -C "$FAKE_HOME/magpie" init -q
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_clone_magpie' run_fn
ret_is "heal re-adds a removed origin" 0
grep_ok "heal checked out file" "$FAKE_HOME/magpie/README.md" "readme"
new_env
FN_BODY='mkdir -p "$HOME/magpie"; magpie_clone_body && magpie_clone_body' run_fn
ret_is "clone body idempotent twice" 0

# ============================================================
sec "full run step"
# ============================================================
# Success path: sandbox command shape + marker + artifacts + feed.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' run_fn
ret_is "full run completes" 0
grep_ok "sandbox run via profile" "$STATE/nono.log" "run --profile magpie-profile --allow-cwd -- env"
grep_ok "madrat mainfolder passed" "$STATE/nono.log" "MADRAT_MAINFOLDER="
grep_ok "renv cache passed" "$STATE/nono.log" "RENV_PATHS_CACHE="
grep_ok "PATH passed" "$STATE/nono.log" "PATH="
grep_ok "bash -c payload" "$STATE/nono.log" "bash -c"
grep_ok "default run script selected" "$STATE/nono.log" "runscripts=default.R submit=direct"
grep_ok "full run sandboxed with allow-cwd" "$STATE/nono.log" "--allow-cwd"
grep_ok "R script invoked" "$STATE/rscript.log" "start.R runscripts=default.R submit=direct"
# One command line, one optional prefix: caffeinate is the darwin half
# of that prefix only - a linux run must never wrap the call.
grep_no "no caffeinate wrapper on linux" "$STATE/caffeinate.log" "caffeinate"
grep_ok "keep-alive dead at full run" "$STATE/keepalive_at_gate.txt" "dead"
grep_ok "hour heads-up" "$STATE/screen.txt" "full magpie run, about an hour"
grep_ok "OK line" "$STATE/screen.txt" "OK: full magpie run finished"
grep_ok "feed start" "$STATE/feed.log" "setup: full run start"
grep_ok "feed finished" "$STATE/feed.log" "setup: full run finished"
file_ok "marker written" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_ok "marker names run folder" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok" \
  '^output/default_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}$'
RUNDIR=$(sed -n 1p "$FAKE_HOME/setup-magpie/.setup-fullrun-ok")
file_ok "fulldata.gdx present" "$FAKE_HOME/magpie/$RUNDIR/fulldata.gdx"
file_ok "report.rds present" "$FAKE_HOME/magpie/$RUNDIR/report.rds"
# Readiness gate FIRST: the probe's sandboxed R call precedes the run
# (nono.log + rscript.log order), and the hydrate announce precedes
# the hour heads-up (screen order) - never a silent long wait.
grep_ok "probe announce printed" "$STATE/screen.txt" \
  "installing R packages, about 10-30 min, just wait"
PN=$(grep -n "library(lucode2)" "$STATE/nono.log" | head -n 1 | cut -d: -f1)
RN=$(grep -n "runscripts=default.R" "$STATE/nono.log" | head -n 1 | cut -d: -f1)
if [ -n "$PN" ] && [ -n "$RN" ] && [ "$PN" -lt "$RN" ]; then
  ok "probe sandboxed before the full run"
else
  no "probe sandboxed before the full run"
fi
PR=$(grep -n "library(gms)" "$STATE/rscript.log" | head -n 1 | cut -d: -f1)
SR=$(grep -n "start.R runscripts" "$STATE/rscript.log" | head -n 1 | cut -d: -f1)
if [ -n "$PR" ] && [ -n "$SR" ] && [ "$PR" -lt "$SR" ]; then
  ok "probe loaded the libraries before start.R ran"
else
  no "probe loaded the libraries before start.R ran"
fi
AN=$(grep -n "installing R packages, about 10-30 min" "$STATE/screen.txt" | head -n 1 | cut -d: -f1)
HN=$(grep -n "full magpie run, about an hour" "$STATE/screen.txt" | head -n 1 | cut -d: -f1)
if [ -n "$AN" ] && [ -n "$HN" ] && [ "$AN" -lt "$HN" ]; then
  ok "announce before the hour heads-up and the run start report"
else
  no "announce before the hour heads-up and the run start report"
fi
# Both prompts start.R's top block can ask ("Update now?" + fixDeps)
# read the piped line, treat an empty one as YES - and WANT yes: a
# skipped bound fix kills the run mid-way, and an update that stops the
# loaded session is healed by the step's fresh-R retry. So the pipe is
# two y lines, prompt-count-independent.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn STUB_FULLRUN_CAPTURE=1
ret_is "prompt-fed run completes" 0
cnt_is "two y answers reach Rscript" "^y$" "$STATE/fullrun_stdin" 2
cnt_is "no n answer is ever piped" "^n$" "$STATE/fullrun_stdin" 0
# A root renv.lock (hand-built teacher tree) changes NOTHING: the same
# two y lines - no branch may key on a lock that never exists in
# course clones (start.R snapshots into renv/archive only).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
: > "$FAKE_HOME/magpie/renv.lock"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn STUB_FULLRUN_CAPTURE=1
ret_is "lockfile run gets the same answers" 0
cnt_is "lockfile changes no answer" "^y$" "$STATE/fullrun_stdin" 2
# Verified marker: rerun skips without touching the sandbox.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00" \
    "$FAKE_HOME/setup-magpie"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' run_fn
ret_is "verified marker skips the run" 0
grep_no "no sandbox run" "$STATE/nono.log" "runscripts=default.R"
grep_no "no R run" "$STATE/rscript.log" "start.R"
grep_ok "skip logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "full run: marker verified"
grep_no "no heads-up on skip" "$STATE/screen.txt" "full magpie run, about an hour"
# Non-zero sandbox exit: straight to the failure verdict, no marker.
# A pass-2 arrival here can only be some OTHER step's retry (the run step
# itself never requests one), so the recorded pass-1 step is realistic.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate" magpie_step_full_run' run_fn STUB_FULLRUN_FAIL=1
ret_is "non-zero sandbox exit fails" 1
grep_ok "failure verdict names the pass-1 step" "$STATE/screen.txt" \
  "SETUP FAILED (pass 2, after: sandbox gate)"
grep_ok "step named" "$STATE/screen.txt" "SETUP FAILED (pass 2, after: sandbox gate): full magpie run (check the run folder under ~/magpie)"
grep_ok "FAIL fed" "$STATE/feed.log" "setup: FAIL full magpie run"
cnt_is "no retry without the restart signature" "runscripts=default.R" "$STATE/nono.log" 1
nofile_ok "no marker on failure" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
# The piped y may let "Update now?" update the already-loaded gms:
# piamenv::stopIfLoaded stops the session ("Please restart R") AFTER
# the renv writes landed - so this ONE exit code earns a fresh R
# session, where the prompts are silent and the model runs.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn STUB_FULLRUN_RESTART=1
ret_is "restart signature earns one fresh R session" 0
cnt_is "R ran exactly twice" "start.R runscripts=default.R submit=direct" "$STATE/rscript.log" 2
grep_ok "restart note on screen" "$STATE/screen.txt" "package update restarted R, model run starts now"
grep_ok "restart logged" "$FAKE_HOME/setup-magpie/setup-log.txt" "R stopped after updating loaded packages"
file_ok "marker written (after restart)" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_ok "finished fed (after restart)" "$STATE/feed.log" "setup: full run finished"
# Two such stops: the retry is capped at ONE - verdict on the second.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate" magpie_step_full_run' run_fn STUB_FULLRUN_RESTART=2
ret_is "restart retry is capped at one" 1
cnt_is "capped at two sessions" "start.R runscripts=default.R submit=direct" "$STATE/rscript.log" 2
grep_ok "capped failure verdict" "$STATE/screen.txt" "SETUP FAILED (pass 2, after: sandbox gate): full magpie run (check the run folder under ~/magpie)"
nofile_ok "no marker after capped retries" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
# I11 gate: a partial library (piamenv there, gms NOT) never
# self-heals, and start.R dies 7 s after the hour was announced.
# The probe catches it BEFORE the run; one rmarkdown-first hydrate
# repair mirrors magpie's .Rprofile bootstrap (a bare hydrate misses
# Rmd-file deps).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn STUB_PROBE_FAILS=1
ret_is "probe fail + repair ok: run proceeds" 0
file_ok "marker written (after repair)" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_ok "repair logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "R library probe failed - one hydrate repair"
grep_ok "repair runs both hydrates, rmarkdown first" "$STATE/rscript.log" \
  'renv::hydrate("rmarkdown".*renv::hydrate(prompt = FALSE, report = FALSE)'
grep_ok "finished fed (after repair)" "$STATE/feed.log" "setup: full run finished"
cnt_is "two probes (initial + re-probe)" "library(gms)" "$STATE/rscript.log" 2
cnt_is "one repair only" "renv::hydrate" "$STATE/rscript.log" 1
# Repair failure = the STANDARD retry pass, still before the hour is
# announced: a transient feed outage gets pass 2 (a re-exec), and no run
# start ever reaches the feed.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
cat > "$STATE/pass2gate.sh" <<'EOS'
#!/bin/sh
echo "PASS2 STEP=$MAGPIE_PASS PASS1STEP=$MAGPIE_PASS1_STEP" > "$STATE/pass2_gate.txt"
EOS
chmod 755 "$STATE/pass2gate.sh"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn "MAGPIE_SELF=$STATE/pass2gate.sh" STUB_PROBE_FAILS=1 STUB_HYDRATE_EXIT=1
ret_is "gate failure hands over to pass 2" 0
grep_ok "pass 2 re-exec names the gate step" "$STATE/pass2_gate.txt" \
  "PASS2 STEP=2 PASS1STEP=course R feed unreachable / R library incomplete - tell the TA"
grep_ok "retry pass 2 announced on the feed" "$STATE/feed.log" \
  "setup: retry pass 2 after: course R feed unreachable / R library incomplete"
grep_ok "auto retry heads-up" "$STATE/screen.txt" "retrying automatically"
grep_no "no failure verdict in pass 1" "$STATE/screen.txt" "SETUP FAILED"
grep_no "no full run start upload" "$STATE/feed.log" "setup: full run start"
grep_no "no hour announce on gate failure" "$STATE/screen.txt" "full magpie run, about an hour"
nofile_ok "no marker on gate failure" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
cnt_is "no second repair" "renv::hydrate" "$STATE/rscript.log" 1
cnt_is "no re-probe after failed repair" "library(gms)" "$STATE/rscript.log" 1
# Same gate still broken in pass 2: the honest verdict, still before any
# run start, still one repair.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="course R feed unreachable / R library incomplete - tell the TA" magpie_step_full_run' \
  run_fn STUB_PROBE_FAILS=1 STUB_HYDRATE_EXIT=1
ret_is "gate failure blocks in pass 2" 1
grep_ok "gate verdict on screen" "$STATE/screen.txt" \
  "SETUP FAILED (twice, reproducible): course R feed unreachable / R library incomplete - tell the TA"
grep_ok "gate verdict fed" "$STATE/feed.log" \
  "setup: FAIL course R feed unreachable / R library incomplete - tell the TA"
grep_no "no full run start upload (pass 2)" "$STATE/feed.log" "setup: full run start"
grep_no "no hour announce on gate failure (pass 2)" "$STATE/screen.txt" \
  "full magpie run, about an hour"
nofile_ok "no marker on gate failure (pass 2)" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
cnt_is "no second repair (pass 2)" "renv::hydrate" "$STATE/rscript.log" 1
cnt_is "no re-probe after failed repair (pass 2)" "library(gms)" "$STATE/rscript.log" 1
# Crash frame (loadNamespace + getLine in the child log, message text
# localized): the gate proved the library loads, so the RUN broke it -
# probe (+ one repair) before the same single retry.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate"
magpie_step_full_run' run_fn STUB_FULLRUN_CRASH=1
ret_is "crash frame earns gate + one retry" 0
file_ok "marker written (after crash retry)" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_ok "crash signature logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "loadNamespace/getLine crash"
grep_ok "crash repair logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "R library probe failed - one hydrate repair"
grep_ok "finished fed (after crash retry)" "$STATE/feed.log" "setup: full run finished"
cnt_is "crash retry is the one and only retry" "start.R runscripts=default.R submit=direct" "$STATE/rscript.log" 2
cnt_is "probes: run gate + retry gate probe + re-probe" "library(gms)" "$STATE/rscript.log" 3
cnt_is "crash repair runs once" "renv::hydrate" "$STATE/rscript.log" 1
# Second crash: the retry stays capped, the verdict is the run one.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate"
magpie_step_full_run' run_fn STUB_FULLRUN_CRASH=2
ret_is "second crash hits the verdict" 1
grep_ok "crash verdict named" "$STATE/screen.txt" \
  "SETUP FAILED (pass 2, after: sandbox gate): full magpie run (check the run folder under ~/magpie)"
nofile_ok "no marker after second crash" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
cnt_is "still one retry" "start.R runscripts=default.R submit=direct" "$STATE/rscript.log" 2
cnt_is "still one repair" "renv::hydrate" "$STATE/rscript.log" 1
cnt_is "no probe without a retry left" "library(gms)" "$STATE/rscript.log" 3
# Only ONE frame name in the child log: the signature is keyed on
# loadNamespace AND getLine - half a frame never earns gate or retry.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate" magpie_step_full_run' \
  run_fn STUB_FULLRUN_ONEFRAME=1
ret_is "one frame name alone does not earn the retry" 1
grep_ok "one-frame verdict is the run verdict" "$STATE/screen.txt" \
  "SETUP FAILED (pass 2, after: sandbox gate): full magpie run (check the run folder under ~/magpie)"
grep_no "one-frame log carries no getLine frame" \
  "$FAKE_HOME/setup-magpie/.setup-fullrun-child.log" "getLine"
grep_ok "one-frame log has the other frame" \
  "$FAKE_HOME/setup-magpie/.setup-fullrun-child.log" "loadNamespace"
cnt_is "one-frame: no retry" "start.R runscripts=default.R submit=direct" "$STATE/rscript.log" 1
cnt_is "one-frame: no second gate" "library(gms)" "$STATE/rscript.log" 1
cnt_is "one-frame: no repair" "renv::hydrate" "$STATE/rscript.log" 0
nofile_ok "no marker on one-frame failure" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
# Exit 0 but swallowed run error (no output artifacts): artifacts fail it.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate" magpie_step_full_run' run_fn STUB_FULLRUN_NO_OUTPUT=1
ret_is "missing postprocessing artifacts fail" 1
grep_ok "artifact failure named" "$STATE/screen.txt" "SETUP FAILED (pass 2, after: sandbox gate): full magpie run (check the run folder under ~/magpie)"
nofile_ok "no marker without artifacts" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_no "no finished feed line" "$STATE/feed.log" "setup: full run finished"
# An OLD complete run folder is not accepted as the NEW one (no-op run).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00" \
    "$FAKE_HOME/setup-magpie"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate" magpie_step_full_run' run_fn STUB_FULLRUN_NOTHING=1
ret_is "old folder is not accepted as new" 1
nofile_ok "no marker without a new folder" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
# Non-zero inner Rscript exit despite COMPLETE artifacts: the exit code
# fails the step too (spec: non-zero sandbox exit fails regardless).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="sandbox gate" magpie_step_full_run' run_fn STUB_FULLRUN_RSCRIPT_EXIT=1
ret_is "non-zero exit with complete artifacts fails" 1
grep_ok "exit-code failure named" "$STATE/screen.txt" "SETUP FAILED (pass 2, after: sandbox gate): full magpie run (check the run folder under ~/magpie)"
nofile_ok "no marker on non-zero exit" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_ok "exit-code FAIL fed" "$STATE/feed.log" "setup: FAIL full magpie run"
# An old complete folder plus a NEW complete folder: the marker names
# the NEWEST one (sort direction).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00" \
    "$FAKE_HOME/setup-magpie"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' run_fn
ret_is "new folder wins over old complete one" 0
file_ok "marker written (newest wins)" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_no "marker is not the old folder" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok" \
  "^output/default_2026-01-01_00\\.00\\.00$"
file_ok "old run folder untouched" \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00/fulldata.gdx"
# Escape hatch: MAGPIE_FULL_RUN=0 -> note + feed + return 0, no marker.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn MAGPIE_FULL_RUN=0
ret_is "escape hatch returns 0" 0
grep_ok "screen note" "$STATE/screen.txt" "Full run skipped (MAGPIE_FULL_RUN=0)"
grep_ok "feed note" "$STATE/feed.log" "setup: full run skipped (MAGPIE_FULL_RUN=0)"
nofile_ok "no marker written" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_no "no sandbox run" "$STATE/nono.log" "runscripts=default.R"
# macOS: the whole call is wrapped in caffeinate -is.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn STUB_FULLRUN_CAPTURE=1
ret_is "darwin full run through caffeinate" 0
grep_ok "caffeinate wraps the call" "$STATE/caffeinate.log" "caffeinate -is nono run --profile magpie-profile"
file_ok "marker written (darwin)" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
cnt_is "prompt answers survive caffeinate" "^y$" "$STATE/fullrun_stdin" 2

# ============================================================
sec "full run check line"
# ============================================================
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "first run is green" 0
grep_no "no full run line before the marker" "$STATE/screen.txt" "full run"
grep_no "no library line before the marker" "$STATE/screen.txt" "R libraries"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00" \
    "$FAKE_HOME/setup-magpie"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "marker + artifacts PASS" 0
grep_ok "PASS line" "$STATE/screen.txt" "PASS full run (output/default_2026-01-01_00.00.00)"
grep_ok "library line with marker" "$STATE/screen.txt" "PASS R libraries (lucode2, gms load)"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "stale marker FAILs" 1
grep_ok "FAIL line" "$STATE/screen.txt" "FAIL full run artifacts missing - rerun this file"
# Each single artifact alone makes a folder-with-marker FAIL the check.
for artifact in fulldata.gdx full.lst report.rds report.mif; do
  new_env
  make_tools
  mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00" \
      "$FAKE_HOME/setup-magpie"
  touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
  rm "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00/$artifact"
  printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
  FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
  ret_is "missing $artifact alone FAILs the check" 1
done
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn MAGPIE_FULL_RUN=0
ret_is "escape hatch check SKIPs" 0
grep_ok "SKIP via env line" "$STATE/screen.txt" "SKIP full run (skipped via MAGPIE_FULL_RUN=0)"

# ============================================================
sec "R library check line"
# ============================================================
# The load probe (lucode2 + gms) replaces the old "renv check" SKIP
# line: with a marker there is a library to test, before it there is
# none - and the probe never runs in the gate child, where a Landlock
# denial would block the setup on a message the student cannot act on.
# The root renv.lock assumption is gone entirely (a root lock never
# exists in course clones): no restore step, no lock-keyed check
# branch - pinned on the source text.
grep_no "no renv restore step in the script" "$SCRIPT" "magpie_step_renv_restore"
grep_no "no renv restore body in the script" "$SCRIPT" "magpie_renv_restore_body"
grep_no "no root lock branch in the script" "$SCRIPT" 'magpie/renv.lock'
put_complete_run() {
  mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00" \
    "$FAKE_HOME/setup-magpie"
  touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
  printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
}
new_env
make_tools
put_complete_run
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn STUB_RENV_EXIT=1
ret_is "broken library FAILs the checks" 1
grep_ok "library FAIL line" "$STATE/screen.txt" \
  "FAIL R libraries incomplete - in ~/magpie run: Rscript start.R once"
grep_ok "probe ran" "$STATE/rscript.log" "library(lucode2)"
new_env
make_tools
put_complete_run
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' \
  run_fn STUB_RENV_EXIT=1 MAGPIE_CHECK_ONLY=1
ret_is "gate child stays green" 0
grep_no "no library line in the child" "$STATE/screen.txt" "R libraries"
grep_no "probe never runs in the child" "$STATE/rscript.log" "library(lucode2)"

# ============================================================
sec "legacy sweep: old ~/magpie state moves, junk goes"
# ============================================================
# All state left by the pre-work-dir layout lives in ~/magpie (logs,
# markers, lock, pid, leftovers) plus ~/.magpie-course-handle and the
# ~/.magpie-course relocation folder. magpie_sweep_legacy moves what
# is valuable and drops what is regenerable - the sweep runs at entry,
# before any step, and every rm is best-effort (a machine where one
# removal fails must still run).
new_env
FN_BODY='echo OLDLOG > "$HOME/magpie/setup-log.txt"
printf "2026-01-01 00:00:00\n" > "$HOME/magpie/.setup-finished"
printf "output/x\n" > "$HOME/magpie/.setup-fullrun-ok"
echo Fox123 > "$HOME/.magpie-course-handle"
mkdir -p "$HOME/.magpie-course/self"
echo OLDSELF > "$HOME/.magpie-course/self/setup-magpie.sh"
echo stale > "$HOME/magpie/setup-help.txt"
echo stale > "$HOME/magpie/setup-help-profile.json"
touch "$HOME/magpie/setup-dl-crashed.pkg" "$HOME/magpie/opencode-dl.tgz"
touch "$HOME/magpie/nono-dl.tar.gz" "$HOME/magpie/.keepalive.pid"
mkdir -p "$HOME/magpie/opencode-extract" "$HOME/magpie/nono-extract"
mkdir -p "$HOME/magpie/.setup.lock"
echo 999999 > "$HOME/magpie/.setup.lock/pid"
magpie_sweep_legacy' run_fn
ret_is "sweep always succeeds" 0
grep_ok "old log moved" "$FAKE_HOME/setup-magpie/setup-log.txt" "OLDLOG"
nofile_ok "old log path empty" "$FAKE_HOME/magpie/setup-log.txt"
grep_ok "finished marker moved" "$FAKE_HOME/setup-magpie/.setup-finished" \
  "2026-01-01"
grep_ok "fullrun marker moved" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok" \
  "output/x"
grep_ok "handle moved with the code name" \
  "$FAKE_HOME/setup-magpie/.magpie-course-handle" "Fox123"
nofile_ok "old handle path gone" "$FAKE_HOME/.magpie-course-handle"
nofile_ok "relocation folder gone" "$FAKE_HOME/.magpie-course"
nofile_ok "help file swept" "$FAKE_HOME/magpie/setup-help.txt"
nofile_ok "profile dump swept" "$FAKE_HOME/magpie/setup-help-profile.json"
nofile_ok "dl leftover swept" "$FAKE_HOME/magpie/setup-dl-crashed.pkg"
nofile_ok "opencode leftover swept" "$FAKE_HOME/magpie/opencode-dl.tgz"
nofile_ok "nono leftover swept" "$FAKE_HOME/magpie/nono-dl.tar.gz"
nofile_ok "keepalive pid swept" "$FAKE_HOME/magpie/.keepalive.pid"
nofile_ok "stale lock dir swept" "$FAKE_HOME/magpie/.setup.lock"
nofile_ok "extract dir swept" "$FAKE_HOME/magpie/opencode-extract"
nofile_ok "nono extract dir swept" "$FAKE_HOME/magpie/nono-extract"
# Conflicts: work-dir state wins (never clobber a current run), the old
# log is APPENDED (history survives), an existing handle is kept.
new_env
FN_BODY='echo OLDLOG > "$HOME/magpie/setup-log.txt"
echo NEWLOG > "$HOME/setup-magpie/setup-log.txt"
echo OLDH > "$HOME/magpie/.setup-fullrun-ok"
echo NEWH > "$HOME/setup-magpie/.setup-fullrun-ok"
echo OLDH > "$HOME/magpie/.setup-finished"
echo NEWH > "$HOME/setup-magpie/.setup-finished"
echo OLD > "$HOME/.magpie-course-handle"
echo NEW > "$HOME/setup-magpie/.magpie-course-handle"
magpie_sweep_legacy' run_fn
ret_is "conflict sweep succeeds" 0
grep_ok "old log appended below the new one" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "OLDLOG"
grep_ok "new log content kept" "$FAKE_HOME/setup-magpie/setup-log.txt" "NEWLOG"
nofile_ok "old log consumed" "$FAKE_HOME/magpie/setup-log.txt"
grep_ok "work dir marker wins" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok" "NEWH"
nofile_ok "shadowed old marker dropped" "$FAKE_HOME/magpie/.setup-fullrun-ok"
grep_ok "existing handle wins" "$FAKE_HOME/setup-magpie/.magpie-course-handle" "NEW"
new_env
# Handle migration through the real entry path (not just the sweep):
# the greet must find the moved code name and keep reporting under it
# - students were told to remember exactly that name.
FN_BODY='echo Fox123 > "$HOME/.magpie-course-handle"
magpie_sweep_legacy; magpie_greet' run_fn
grep_ok "greet reuses the migrated name" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "reporting status as Fox123"
nofile_ok "old handle path gone" "$FAKE_HOME/.magpie-course-handle"
new_env
FN_BODY='magpie_sweep_legacy; magpie_greet' run_fn
grep_ok "no old handle: fresh name at the new path" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "reporting status as [A-Z][a-z]*[0-9][0-9][0-9]"
file_ok "fresh handle lands in the work dir" \
  "$FAKE_HOME/setup-magpie/.magpie-course-handle"
new_env
# Full old-layout machine, end to end: state in ~/magpie, code name at
# the old path, 9P copy folder present. The new script migrates the
# valuable pieces, verifies the moved full-run marker against the run
# artifacts still in the clone (marker content is clone-relative,
# nothing under output/ moves - no 40-minute rerun), installs green -
# and the student keeps the code name they wrote down.
E2E_SCRIPT="$ENV/magpie_lic.sh"
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00" \
  "$FAKE_HOME/magpie/opencode-extract" "$FAKE_HOME/magpie/nono-extract" \
  "$FAKE_HOME/magpie/.setup.lock" "$FAKE_HOME/.magpie-course/self"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
printf '2026-01-01 00:00:00\nnono 0.81.0\nopencode 2.2.7\n' > "$FAKE_HOME/magpie/.setup-finished"
echo 'OLD-LAYOUT-LOG' > "$FAKE_HOME/magpie/setup-log.txt"
echo 'Fox123' > "$FAKE_HOME/.magpie-course-handle"
echo junk > "$FAKE_HOME/magpie/setup-help.txt"
echo '{}' > "$FAKE_HOME/magpie/setup-help-profile.json"
echo junk > "$FAKE_HOME/magpie/setup-dl-crashed.pkg"
echo junk > "$FAKE_HOME/magpie/opencode-dl.tgz"
echo junk > "$FAKE_HOME/magpie/nono-dl.tar.gz"
echo junk > "$FAKE_HOME/magpie/.keepalive.pid"
echo 999999 > "$FAKE_HOME/magpie/.setup.lock/pid"
echo 'OLD-SELF' > "$FAKE_HOME/.magpie-course/self/setup-magpie.sh"
# the old install's clone (healed in place, not re-cloned)
git -C "$FAKE_HOME/magpie" init -q
git -C "$FAKE_HOME/magpie" remote add origin "file://$STATE/origin.git"
git -C "$FAKE_HOME/magpie" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m init
run_e2e
ret_is "old layout migrates to a green run" 0
grep_ok "existing clone recognized" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "magpie: already cloned"
grep_ok "migrated marker verified, no rerun" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "full run: marker verified"
grep_no "no fresh hour-long run on a migrated marker" "$STATE/screen.txt" \
  "full magpie run, about an hour"
grep_ok "migrated marker intact" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok" \
  "output/default_2026-01-01_00.00.00"
grep_ok "old log content moved into the work dir log" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "OLD-LAYOUT-LOG"
grep_ok "student keeps the code name" \
  "$FAKE_HOME/setup-magpie/setup-log.txt" "reporting status as Fox123"
grep_ok "run verdict" "$STATE/screen.txt" "SETUP COMPLETE"
nofile_ok "old handle path gone" "$FAKE_HOME/.magpie-course-handle"
nofile_ok "relocation folder gone" "$FAKE_HOME/.magpie-course"
nofile_ok "old log moved away" "$FAKE_HOME/magpie/setup-log.txt"
nofile_ok "old markers moved away" "$FAKE_HOME/magpie/.setup-fullrun-ok"
nofile_ok "junk help files gone" "$FAKE_HOME/magpie/setup-help.txt"
nofile_ok "stale lock gone" "$FAKE_HOME/magpie/.setup.lock"
nofile_ok "dl leftovers gone" "$FAKE_HOME/magpie/opencode-dl.tgz"

# ============================================================
sec "E2E day-one green run"
# ============================================================
new_env
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e
ret_is "day one exits 0" 0
S="$STATE/screen.txt"
grep_ok "opencode OK line" "$S" "OK: opencode 9.9.9 installed"
grep_ok "nono OK line" "$S" "OK: nono 9.9.9 installed"
grep_ok "tools OK line" "$S" "OK: R + support packages installed"
grep_ok "TinyTeX OK line" "$S" "OK: TinyTeX installed"
grep_ok "GAMS OK line" "$S" "OK: GAMS 54.6.1 installed"
grep_no "licence path off screen" "$S" "Course licence written"
grep_ok "licence written logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "course licence written"
grep_no "profile pull OK off screen" "$S" "OK: nono profile opencode pulled"
grep_ok "profile pull logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "nono profile opencode pulled"
grep_no "magpie-profile OK off screen" "$S" "magpie-profile in place"
grep_ok "magpie-profile logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "magpie-profile in place"
grep_no "PATH plumbing off screen" "$S" "Added opencode to PATH"
grep_ok "PATH add logged" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "added opencode to PATH"
grep_ok "clone OK line" "$S" "OK: magpie downloaded"
# 8 = the seven install announces + the readiness probe's hydrate
# heads-up (the full run's library gate).
cnt_is "exactly 8 heads-ups" "installing" "$S" 8
grep_no "apt skipped no heads-up" "$S" "installing git + curl"
grep_no "no failure verdict" "$S" "SETUP FAILED"
grep_ok "greet logs the handle on first run" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "reporting status as"
grep_no "no greet line on screen" "$S" "Reporting status as"
grep_no "no CONOPT note in the green run" "$S" "CONOPT"
grep_no "no blind sudo prompt" "$S" "Type it blind"
grep_ok "all checks PASS" "$S" "PASS gams"
grep_ok "check block names the code name" "$S" "code name: "
grep_no "no renv R library line (root lock gone)" "$S" "renv R library"
grep_no "no library line before the marker" "$S" "R libraries"
grep_no "no full run line before the marker" "$S" "SKIP full run"
grep_ok "full run heads-up" "$S" "full magpie run, about an hour"
grep_ok "full run OK line" "$S" "OK: full magpie run finished"
grep_ok "verdict block" "$S" "SETUP COMPLETE - MAgPIE is installed, checked and working"
grep_ok "verdict names the run folder" "$S" "default run: output/default_"
grep_no "no ## banner on a green run" "$S" "##"
grep_no "old rerun-setup hint gone" "$S" "rerun this setup file"
# feed protocol
grep_ok "feed start" "$STATE/feed.log" "setup: start"
# masked hash (--script-hash): fill-ins excluded, so the header carries
# the build's one hash - same as the repo copy and every filled variant.
WANTV=$(script_hash "$E2E_SCRIPT")
grep_ok "feed carries script hash" "$STATE/feed.log" " | v$WANTV | setup: start"
grep_no "no fake home in feed" "$STATE/feed.log" "$FAKE_HOME"
grep_ok "feed check result block" "$STATE/feed.log" "check result"
grep_ok "feed PASS gams line" "$STATE/feed.log" "PASS gams"
grep_ok "feed full run start" "$STATE/feed.log" "setup: full run start"
grep_ok "feed full run finished" "$STATE/feed.log" "setup: full run finished"
grep_ok "feed run finished" "$STATE/feed.log" "setup: run finished"
grep_no "no FAIL on the feed" "$STATE/feed.log" "FAIL"
# upload shape: PUT into the share, one file per post, no credentials
grep_ok "feed posts are PUT uploads" "$STATE/feed_url.log" \
  "PUT https://cloud\.pik-potsdam\.de/public\.php/webdav/"
grep_ok "upload name holds handle and date" "$STATE/feed_url.log" \
  "webdav/[A-Za-z][A-Za-z]*[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]"
grep_no "no credentials in upload urls" "$STATE/feed_url.log" "@"
# curl output stays suppressed (-s, -o /dev/null): the stub emits a
# response body + progress noise, none of it may reach the student log.
grep_no "no upload response noise in the log" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "stub-response-noise"
grep_no "no upload progress noise in the log" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "stub-progress-noise"
# state on disk
file_ok "clone checked out" "$FAKE_HOME/magpie/README.md"
file_ok "log under ~/setup-magpie" "$FAKE_HOME/setup-magpie/setup-log.txt"
# The log has to END with the verdict: tail -n 1 answers "did it work?"
if tail -n 1 "$FAKE_HOME/setup-magpie/setup-log.txt" \
  | grep -q "SETUP COMPLETE - all checks passed, full run output/default_"; then
  ok "log's last line is the verdict"
else
  no "log's last line is the verdict [got: $(tail -n 1 "$FAKE_HOME/setup-magpie/setup-log.txt")]"
fi
nofile_ok ".setup-finished never written" "$FAKE_HOME/setup-magpie/.setup-finished"
nofile_ok "lock released" "$FAKE_HOME/setup-magpie/.setup.lock"
nofile_ok "no setup-dl leftovers" "$FAKE_HOME/setup-magpie/setup-dl-gams.exe"
ls "$FAKE_HOME/setup-magpie" | grep -q '^setup-dl-' \
  && no "no setup-dl-* leftovers" || ok "no setup-dl-* leftovers"
T="$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
grep_ok "licence in gams dir" "$T" "TEST-LICENCE-CONTENT"
mode_is "licence mode 600" "$T" 600
grep_ok "profile json read list has gams" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" "$FAKE_HOME/gams"
cnt_is "rc dedupe opencode" ".opencode/bin" "$FAKE_HOME/.bashrc" 1
cnt_is "rc dedupe nono" ".nono/bin" "$FAKE_HOME/.bashrc" 1
cnt_is "rc HU key once" "HU_API_KEY" "$FAKE_HOME/.bashrc" 1
grep_ok "rc gams dir line" "$FAKE_HOME/.bashrc" "gams54.6.1_linux_x64_64_sfx"
grep_ok "rc texbin line" "$FAKE_HOME/.bashrc" ".TinyTeX/bin"
grep_ok "tex registered" "$FAKE_HOME/setup-magpie/setup-log.txt" "TinyTeX registered"
grep_ok "pull pinned" "$STATE/nono.log" "pull nolabs-ai/opencode@9.9.9"
grep_ok "gate ran" "$STATE/nono.log" "--profile magpie-profile"
grep_ok "keep-alive dead at gate" "$STATE/keepalive_at_gate.txt" "dead"
grep_ok "sudo cooled before gate" "$STATE/sudo.log" "sudo -k"
grep_no "gate child output off screen (E2E)" "$S" "GATE-CHILD-OUTPUT-MARKER"
grep_ok "gate child output in log (E2E)" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "GATE-CHILD-OUTPUT-MARKER"
grep_no "nono banner off screen (E2E)" "$S" "NONO-BANNER-MARKER"
grep_ok "nono banner in log (E2E)" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "NONO-BANNER-MARKER"
grep_ok "sandbox check OK line on screen" "$S" "OK: sandbox check passed"
grep_no "no sudo -v (all silent)" "$STATE/sudo.log" "sudo -v"
file_ok "full run marker" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
RUNREL=$(sed -n 1p "$FAKE_HOME/setup-magpie/.setup-fullrun-ok" 2>/dev/null)
file_ok "marker folder holds fulldata.gdx" "$FAKE_HOME/magpie/$RUNREL/fulldata.gdx"
file_ok "marker folder holds report.rds" "$FAKE_HOME/magpie/$RUNREL/report.rds"
file_ok "madrat mainfolder dir created" "$FAKE_HOME/.madrat"
file_ok "renv cache dir created" "$FAKE_HOME/.cache/R/renv"
cnt_is "rc MADRAT line once" "MADRAT_MAINFOLDER" "$FAKE_HOME/.bashrc" 1
cnt_is "rc RENV line once" "RENV_PATHS_CACHE" "$FAKE_HOME/.bashrc" 1
grep_ok "profile write list holds madrat" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" "$FAKE_HOME/.madrat"

# second run: everything skips
run_e2e
ret_is "second run exits 0" 0
cnt_is "all steps skip (0 heads-ups)" "installing" "$STATE/screen.txt" 0
grep_no "handle box not repeated" "$STATE/screen.txt" "NOTE IT DOWN"
cnt_is "rc lines stay deduped" ".opencode/bin" "$FAKE_HOME/.bashrc" 1
grep_ok "licence already in place" "$FAKE_HOME/setup-magpie/setup-log.txt" "already in place"
cnt_is "feed start twice over two runs" "setup: start" "$STATE/feed.log" 2
grep_ok "second run also finished" "$FAKE_HOME/setup-magpie/setup-log.txt" "magpie: already cloned"
grep_ok "second run checks full run PASS" "$STATE/screen.txt" "PASS full run (output/default_"
grep_ok "second run skipped the run" "$FAKE_HOME/setup-magpie/setup-log.txt" "full run: marker verified"
cnt_is "start.R ran once over two runs" "runscripts=default.R" "$STATE/rscript.log" 1
# A rerun of a finished install must not end in silence (spec 10): the
# screen file is rewritten per run_e2e, so this line is from run 2 -
# the verdict prints on the marker-verified short-circuit too.
grep_ok "verdict on the rerun path" "$STATE/screen.txt" \
  "SETUP COMPLETE - MAgPIE is installed, checked and working"
# And it is the log's last line again (log accumulates, tail = run 2).
if tail -n 1 "$FAKE_HOME/setup-magpie/setup-log.txt" \
  | grep -q "SETUP COMPLETE - all checks passed, full run output/default_"; then
  ok "log's last line is the verdict (rerun)"
else
  no "log's last line is the verdict (rerun) [got: $(tail -n 1 "$FAKE_HOME/setup-magpie/setup-log.txt")]"
fi

# Transient course-feed outage at the readiness gate: pass 1 gets the
# standard retry pass, pass 2's gate passes, and the hour is announced
# exactly once over the whole run (no double announcement after a
# re-entry, and the run still lands).
new_env
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e STUB_PROBE_FAILS=1 STUB_HYDRATE_EXIT=1
ret_is "gate outage recovers through pass 2" 0
grep_ok "gate retry fed" "$STATE/feed.log" \
  "setup: retry pass 2 after: course R feed unreachable / R library incomplete"
cnt_is "hour announced exactly once" "full magpie run, about an hour" "$STATE/screen.txt" 1
file_ok "full run marker after the retry pass" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
cnt_is "start.R ran once" "runscripts=default.R" "$STATE/rscript.log" 1
grep_ok "verdict after the retry pass" "$STATE/screen.txt" \
  "SETUP COMPLETE - MAgPIE is installed, checked and working"

# ============================================================
sec "version hash masks the teacher fill-ins"
# ============================================================
# The feed's v<hash> identifies a BUILD: identical across the plain,
# licence-pasted, blank-heredoc and nofeed copies, different from the
# raw file hash - so the teacher records ONE hash per build and the
# agent matches every student copy against it.
new_env
HV=$(script_hash "$ENV/magpie.sh")
HV_LIC=$(script_hash "$ENV/magpie_lic.sh")
HV_BLANK=$(script_hash "$ENV/magpie_lic_blank.sh")
HV_NOFEED=$(script_hash "$ENV/magpie_nofeed.sh")
if [ "$HV" = "$HV_LIC" ] && [ "$HV" = "$HV_BLANK" ] \
  && [ "$HV" = "$HV_NOFEED" ]; then
  ok "one hash across plain/pasted/blank/nofeed copies"
else
  no "one hash across plain/pasted/blank/nofeed copies \
[$HV/$HV_LIC/$HV_BLANK/$HV_NOFEED]"
fi
# Production invariant on the repo file itself: filling in licence +
# credentials the way a teacher does must not move its hash. (The
# per-env templates carry replaced pins, so they hash differently by
# design - compare a fill-in pair, not templates against the repo.)
sed -e 's|^STATUS_URL=.*|STATUS_URL="https://tok:pw@cloud.example/webdav"|' \
  -e '/^__PASTE_CONTENTS_OF_gamslice.txt_HERE__$/s|__PASTE_CONTENTS_OF_gamslice.txt_HERE__|TEACHER-PASTED-LICENCE|' \
  "$SCRIPT" > "$ENV/magpie_repo_filled.sh"
chmod +x "$ENV/magpie_repo_filled.sh"
HV_REPO=$(script_hash "$SCRIPT")
HV_RFILL=$(script_hash "$ENV/magpie_repo_filled.sh")
if [ -n "$HV_REPO" ] && [ "$HV_REPO" = "$HV_RFILL" ]; then
  ok "repo file hashes the same as its filled-in copy"
else
  no "repo file hashes the same as its filled-in copy [$HV_REPO/$HV_RFILL]"
fi
if printf '%s\n' "$HV" | grep -Eq '^[0-9a-f]{12}$'; then
  ok "masked hash is 12 hex"
else
  no "masked hash is 12 hex [$HV]"
fi
RAWV=$(sha256sum "$ENV/magpie_lic.sh" | cut -d ' ' -f 1 | cut -c1-12)
if [ "$HV_LIC" != "$RAWV" ]; then
  ok "masked hash differs from raw file hash"
else
  no "masked hash differs from raw file hash"
fi
# Edits OUTSIDE the fill-ins must still change the hash (unknown hash
# on the feed = edited download), so masking must not be over-broad.
sed 's|^MAGPIE_COURSE_LICENSEE=.*|MAGPIE_COURSE_LICENSEE="Edited-Away"|' \
  "$ENV/magpie.sh" > "$ENV/magpie_edited.sh"
chmod +x "$ENV/magpie_edited.sh"
HV_EDIT=$(script_hash "$ENV/magpie_edited.sh")
if [ "$HV_EDIT" != "$HV" ]; then
  ok "edit outside the fill-ins changes the hash"
else
  no "edit outside the fill-ins changes the hash"
fi
# The flag is a pure read: entry exits before log, handle, lock or feed.
nofile_ok "--script-hash creates no ~/magpie" "$FAKE_HOME/magpie"
nofile_ok "--script-hash creates no work dir" "$FAKE_HOME/setup-magpie"
nofile_ok "--script-hash posts nothing to the feed" "$STATE/feed.log"

# ============================================================
sec "E2E sudo prompt: keep-alive stopped before the gate"
# ============================================================
# The day-one run above is fully sudo-silent. Here sudo -n always
# fails, so the warm loop prompts and a keep-alive is really running
# for the whole install. It must be dead AT the gate instant.
new_env
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e STUB_SUDO_N_OK=0
ret_is "prompt run exits 0" 0
grep_ok "blind prompt happened" "$STATE/screen.txt" "Type it blind"
grep_ok "keep-alive dead at gate (live run)" "$STATE/keepalive_at_gate.txt" "dead"
nofile_ok "pidfile gone after run" "$FAKE_HOME/setup-magpie/.keepalive.pid"
# The prompt warmed a credential: it must be gone before gate + full
# run (gate unit + day-one E2E already cover the silent shape).
grep_ok "sudo cooled after prompt run" "$STATE/sudo.log" "sudo -k"
grep_ok "no warm sudo at gate or full run" "$STATE/sudo_at_gate.txt" "cool"
grep_no "no warm sudo anywhere at sandbox time" "$STATE/sudo_at_gate.txt" "warm"
grep_ok "prompt run finished" "$STATE/feed.log" "run finished"

# ============================================================
sec "E2E MAGPIE_FULL_RUN=0 (escape hatch)"
# ============================================================
new_env
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e MAGPIE_FULL_RUN=0
ret_is "green with the full run skipped" 0
grep_ok "screen note" "$STATE/screen.txt" "Full run skipped (MAGPIE_FULL_RUN=0)"
grep_ok "check SKIP line" "$STATE/screen.txt" "SKIP full run (skipped via MAGPIE_FULL_RUN=0)"
grep_ok "feed skip note" "$STATE/feed.log" "setup: full run skipped (MAGPIE_FULL_RUN=0)"
grep_ok "verdict: skipped note" "$STATE/screen.txt" "default run: skipped (MAGPIE_FULL_RUN=0)"
grep_ok "log verdict: skipped note" "$FAKE_HOME/setup-magpie/setup-log.txt" \
  "SETUP COMPLETE - all checks passed, full run skipped (MAGPIE_FULL_RUN=0)"
grep_ok "still run finished" "$STATE/feed.log" "setup: run finished"
nofile_ok "no marker written" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
grep_no "no start.R invocation" "$STATE/rscript.log" "runscripts=default.R"
# Placeholder licence (plain script copy): the warning fires once per
# run on screen and on the feed (setup_path early check + install_licence
# share one cached result). On a machine that already carries the course
# gamslice (installed earlier), the run stays green.
new_env
make_installed
run_e2e MAGPIE_FULL_RUN=0
ret_is "placeholder run completes" 0
cnt_is "licence warning once on screen" "not embedded" "$STATE/screen.txt" 1
cnt_is "licence warning once on feed" "gamslice not embedded" "$STATE/feed.log" 1

# ============================================================
sec "E2E deleted artifacts -> FAIL -> marker removal heals"
# ============================================================
new_env
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e
ret_is "green first" 0
RUNREL=$(sed -n 1p "$FAKE_HOME/setup-magpie/.setup-fullrun-ok")
rm -rf "$FAKE_HOME/magpie/$RUNREL"
run_e2e
ret_is "missing artifacts block the rerun" 1
grep_ok "full run FAIL line" "$STATE/screen.txt" "FAIL full run artifacts missing - rerun this file"
grep_ok "failure verdict" "$STATE/screen.txt" "SETUP FAILED: checks"
grep_ok "FAIL fed" "$STATE/feed.log" "setup: FAIL checks"
# Recovery: delete the marker, the step redoes the run.
rm -f "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
run_e2e
ret_is "heals after marker removal" 0
grep_no "no full run line before the fresh run" "$STATE/screen.txt" "SKIP full run"
grep_ok "verdict after healing" "$STATE/screen.txt" \
  "SETUP COMPLETE - MAgPIE is installed, checked and working"
file_ok "marker rewritten" "$FAKE_HOME/setup-magpie/.setup-fullrun-ok"
RUNREL=$(sed -n 1p "$FAKE_HOME/setup-magpie/.setup-fullrun-ok")
file_ok "new run folder complete" "$FAKE_HOME/magpie/$RUNREL/report.mif"

# ============================================================
sec "E2E reproducible failure -> pass 2 -> failure verdict"
# ============================================================
new_env
run_e2e STUB_BAD_ARCHIVE=1
ret_is "corrupt download blocks" 1
S="$STATE/screen.txt"
grep_ok "failure verdict" "$S" "SETUP FAILED (twice, reproducible)"
grep_ok "failed step named" "$S" "SETUP FAILED (twice, reproducible): opencode install"
grep_no "no wifi hint text" "$S" "Wi-Fi"
grep_no "no hint lines in verdict" "$S" "run this file again"
grep_ok "code name in verdict" "$S" "code name:"
cnt_is "retry heads-up once per pass" "retrying automatically" "$S" 1
cnt_is "failing step logged in both passes" "step failed after retries" "$FAKE_HOME/setup-magpie/setup-log.txt" 2
grep_ok "FAIL line on the feed" "$STATE/feed.log" "setup: FAIL opencode install"
grep_ok "retry pass 2 announced on feed" "$STATE/feed.log" "setup: retry pass 2 after: opencode install"
grep_no "run not finished" "$STATE/feed.log" "run finished"
nofile_ok "no lock left behind" "$FAKE_HOME/setup-magpie/.setup.lock"
ls "$FAKE_HOME/setup-magpie" | grep -q '^setup-dl-' \
  && no "crash leaves no setup-dl-*" || ok "crash leaves no setup-dl-*"
nofile_ok "no help file written" "$FAKE_HOME/magpie/setup-help.txt"
new_env
# lic copy: a fresh install ships the demo gamslice, which only an
# embedded course gamslice replaces - so the run can reach its verdict.
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e STUB_CURL_DL_FAILS=1
ret_is "transient download failure heals" 0
grep_no "no failure heads-up" "$STATE/screen.txt" "retrying automatically"

# ============================================================
sec "feed v2: sanitize, combined FAIL, cap, crash, retry, transport"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_report "home=$HOME host=$(uname -n) user=$(id -un)"' run_fn
grep_ok "home replaced by ~" "$STATE/feed.log" "home=~ "
grep_ok "host replaced" "$STATE/feed.log" "host=HOST"
grep_ok "user replaced by code name" "$STATE/feed.log" "user=T1"
grep_ok "unit feed falls back to vunknown" "$STATE/feed.log" "vunknown"
grep_no "no real username in feed" "$STATE/feed.log" "$(id -un)"
grep_no "no real hostname in feed" "$STATE/feed.log" "$(uname -n)"
grep_no "no real home path in feed" "$STATE/feed.log" "$FAKE_HOME"
grep_ok "upload PUT into the share" "$STATE/feed_url.log" \
  "PUT https://cloud\.pik-potsdam\.de/public\.php/webdav/T1-"
grep_ok "upload name is a .log file" "$STATE/feed_url.log" "/T1-.*\.log$"
# .local hostnames (macOS) are filtered in both shapes; the account's
# real name too (fake uname + getent for a deterministic scenario).
new_env
cat > "$FAKE_BIN/uname" <<'EOS'
#!/bin/sh
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *) echo testhost.local ;;
esac
EOS
cat > "$FAKE_BIN/getent" <<'EOS'
#!/bin/sh
echo "testuser:x:1000:1000:Testy Tester:/home/testuser:/bin/sh"
EOS
chmod 755 "$FAKE_BIN/uname" "$FAKE_BIN/getent"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_report "signed Testy Tester on testhost.local and testhost today"' run_fn
grep_ok "real name replaced" "$STATE/feed.log" "signed T1 on"
grep_ok "host and host base replaced" "$STATE/feed.log" "on HOST and HOST today"
grep_no "no testhost in feed" "$STATE/feed.log" "testhost"
grep_no "no real name in feed" "$STATE/feed.log" "Testy"
# Token boundaries: the username inside a longer word survives, the
# username as its own token (also before "/") is replaced.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_report "keep $(id -un)x and $(id -un)/x"' run_fn
grep_ok "username inside word kept" "$STATE/feed.log" "keep $(id -un)x and"
grep_ok "username token replaced" "$STATE/feed.log" "and T1/x"
# Two posts inside the same second must not replace each other (PUT
# overwrites on the target).
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_report "first post"; magpie_report "second post"' run_fn
cnt_is "two posts make two uploads" "PUT " "$STATE/feed_url.log" 2
grep_ok "first post keeps counter 1" "$STATE/feed_url.log" "/T1-.*-1\.log$"
grep_ok "second post keeps counter 2" "$STATE/feed_url.log" "/T1-.*-2\.log$"
grep_ok "both bodies recorded" "$STATE/feed.log" "second post"
# Exact name shape: handle-date-time-pid-counter (pid separates runs).
grep_ok "upload name holds date, pid and counter" "$STATE/feed_url.log" \
  "/T1-[0-9]\{8\}-[0-9]\{6\}-[0-9]\+-[0-9]\+\.log$"

# No handle yet (early crash): header and username fallback = unknown.
new_env
FN_BODY='MAGPIE_OS=linux; magpie_report "user=$(id -un)"' run_fn
grep_ok "header falls back to unknown" "$STATE/feed.log" "^unknown | "
grep_ok "user falls back to unknown" "$STATE/feed.log" "user=unknown"

# Combined FAIL post: block content in the feed, cap cuts deep tail.
new_env
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
# One awk process (~800 forks saved; bytes identical to the old
# head|tr loop, verified with cmp).
awk 'BEGIN{
  x = ""
  for (j = 0; j < 200; j++) x = x "x"
  for (i = 1; i <= 401; i++) {
    if (i == 377) printf "TAILKEEP %s\n", x
    else if (i == 400) printf "TAILCUT %s\n", x
    else if (i == 401) print "LASTLINE short"
    else printf "filler %d %s\n", i, x
  }
}' > "$FAKE_HOME/setup-magpie/setup-log.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_fail "cap step"' run_fn
ret_is "capped fail exits 1" 1
grep_ok "FAIL header keeps step" "$STATE/feed.log" "vunknown | setup: FAIL cap step"
grep_ok "code name in the posted detail" "$STATE/feed.log" "code name: T1"
grep_ok "FAILED STEP line in feed" "$STATE/feed.log" "FAILED STEP: cap step"
grep_no "first pass never claims reproducibility" "$STATE/feed.log" \
  "FAILED STEP (twice, reproducible)"
grep_ok "log tail start survives cap" "$STATE/feed.log" "TAILKEEP"
grep_no "deep tail cut by cap" "$STATE/feed.log" "TAILCUT"
grep_ok "screen names the step" "$STATE/screen.txt" "SETUP FAILED: cap step"
grep_no "no twice-claim on screen first pass" "$STATE/screen.txt" \
  "SETUP FAILED (twice, reproducible)"
grep_ok "screen points at the log" "$STATE/screen.txt" "everything else: "
nofile_ok "no help file written" "$FAKE_HOME/magpie/setup-help.txt"
# Pass 2 = the sequence really ran twice (same step in both passes):
# the claim is honest again.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 MAGPIE_PASS1_STEP="cap step" magpie_fail "cap step"' run_fn
ret_is "pass-2 fail exits 1" 1
grep_ok "pass-2 feed keeps the twice-claim" "$STATE/feed.log" \
  "FAILED STEP (twice, reproducible): cap step"
grep_ok "pass-2 screen keeps the twice-claim" "$STATE/screen.txt" \
  "SETUP FAILED (twice, reproducible): cap step"

# No feed at all (teacher left STATUS_URL empty, or no curl): nothing can
# be uploaded, so the log tail must reach the screen instead of only the
# feed pointer line. STATUS_URL is a source-time constant, so FN_BODY
# clears it after sourcing.
new_env
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
printf '[2026-11-17 00:00:00] the real error line\n' > "$FAKE_HOME/setup-magpie/setup-log.txt"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; STATUS_URL=; magpie_fail "offline step"' run_fn
ret_is "offline fail exits 1" 1
grep_ok "log tail on screen without a feed" "$STATE/screen.txt" \
  "--- last 25 log lines ---"
grep_ok "the error line itself on screen" "$STATE/screen.txt" "the real error line"
nofile_ok "no upload attempted without a feed" "$STATE/curl.log"

# Crash reporting from the EXIT trap.
new_env
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_log "before the crash"; exit 3' run_fn
ret_is "body exit 3 propagates" 3
grep_ok "crash reported" "$STATE/feed.log" "setup: CRASH exit=3"
grep_ok "crash carries log tail" "$STATE/feed.log" "before the crash"
new_env
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; false' run_fn
ret_is "silent exit 1 propagates" 1
grep_ok "unreported exit 1 is a crash" "$STATE/feed.log" "setup: CRASH exit=1"
new_env
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_fail "posted step"' run_fn
ret_is "fail exits 1" 1
grep_no "no crash line after FAIL post" "$STATE/feed.log" "CRASH"
# with a live feed the screen gets only the pointer lines - the log
# tail belongs to the no-feed case (spec 7: it goes to the screen
# *instead of* the feed pointer, never alongside it)
grep_no "log tail stays off screen with a live feed" "$STATE/screen.txt" "--- last 25 log lines ---"
new_env
mkdir -p "$FAKE_HOME/magpie" "$FAKE_HOME/setup-magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; MAGPIE_CHECK_ONLY=1; exit 3' run_fn
ret_is "check-only exit 3 propagates" 3
grep_no "no crash line from check-only child" "$STATE/feed.log" "CRASH"

# Retry pass 2 announce (MAGPIE_SELF=/bin/true: exec ends the unit).
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; MAGPIE_SELF="$MINBIN/true"; magpie_step_failed "wifi blip"' run_fn
ret_is "retry execs the self script" 0
grep_ok "retry pass 2 announced" "$STATE/feed.log" "setup: retry pass 2 after: wifi blip"

# Upload transport: a failing upload (401, dead server) never breaks a
# run; a bad TMPDIR (mktemp failure) is a silent no-op; an empty feed
# URL uploads nothing at all.
new_env
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e STUB_FEED_FAIL=22
ret_is "upload failures are ignored" 0
grep_ok "run finished despite upload failures" "$STATE/feed.log" "setup: run finished"
grep_ok "uploads were still attempted" "$STATE/feed_url.log" \
  "PUT https://cloud\.pik-potsdam\.de/public\.php/webdav/"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_report "endpoint down"' run_fn STUB_FEED_FAIL=22
ret_is "failing upload never fails the caller" 0
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; TMPDIR=/nonexistent magpie_report "never uploaded"' run_fn
ret_is "mktemp failure stays silent" 0
nofile_ok "no curl call on mktemp failure" "$STATE/curl.log"
# Teacher's filled-in copy: a share credential in the URL must never
# reach any test artifact, while the upload itself still goes through.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; STATUS_URL=https://tok123:pw456@cloud.pik-potsdam.de/public.php/webdav; magpie_report "filled link post"' run_fn
grep_ok "filled share link still uploads" "$STATE/feed_url.log" \
  "PUT https://cloud\.pik-potsdam\.de/public\.php/webdav/T1-"
grep_no "share token never in upload urls" "$STATE/feed_url.log" "tok123"
grep_no "share password never in upload urls" "$STATE/feed_url.log" "pw456"
grep_no "share token never in feed bodies" "$STATE/feed.log" "tok123"
# A password that itself holds "@" (curl splits userinfo at the LAST
# "@"): the stub must strip the whole userinfo, not stop at the first.
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; STATUS_URL=https://tok123:pa@ss@cloud.pik-potsdam.de/public.php/webdav; magpie_report "at-password post"' run_fn
grep_ok "at-password url fully stripped" "$STATE/feed_url.log" \
  "PUT https://cloud\.pik-potsdam\.de/public\.php/webdav/T1-"
grep_no "no @ left in upload urls" "$STATE/feed_url.log" "@"
new_env
E2E_SCRIPT="$ENV/magpie_nofeed.sh"
run_e2e
ret_is "run without feed succeeds" 0
nofile_ok "no upload when feed URL is empty" "$STATE/feed_url.log"
nofile_ok "no feed body when feed URL is empty" "$STATE/feed.log"

# ============================================================
printf '\n========================================\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_N" "$FAIL_N"
[ "$FAIL_N" = 0 ] || exit 1
exit 0
