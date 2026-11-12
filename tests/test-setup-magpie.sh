#!/usr/bin/env bash
# Offline harness for setup-magpie.sh. Fake HOME, stub binaries only.
# Nothing touches the network (the curl stub records feed POSTs locally).
set -u
umask 077

# magpie_init_handle reads /dev/tty. Wherever /dev/tty is openable
# (interactive terminal) that read could block forever. Re-exec
# detached (new session, no controlling terminal) so /dev/tty fails
# and the run never waits.
if [ -z "${MAGPIE_HARNESS_DETACHED:-}" ] \
  && command -v setsid >/dev/null 2>&1 \
  && ( : </dev/tty ) 2>/dev/null \
  && setsid -w /bin/true >/dev/null 2>&1; then
  MAGPIE_HARNESS_DETACHED=1
  export MAGPIE_HARNESS_DETACHED
  exec setsid -w bash "$0" "$@"
fi

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../setup-magpie.sh"
RUNROOT="$HERE/../.tmp/testrun-setup"
rm -rf "$RUNROOT"
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
  # Only these core tools exist for the tested script (host tex/pandoc/
  # Rscript/gams on PATH would shadow the stubs and trigger REAL downloads).
  for tool in bash cmp awk basename cat chmod cp cut date dirname env git \
    head ln ls mkdir mv od rm sed sha256sum shasum sleep sort stat tail tar gzip \
    tr touch grep mktemp sh uname; do
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
    mkdir -p "$HOME/.config/nono/packages/nolabs-ai/opencode"
    echo "{\"name\":\"opencode\",\"version\":\"$ver\"}" \
      > "$HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
    exit 0
    ;;
  pin) exit 0 ;;
  profile)
    if [ "${2:-}" = validate ]; then
      echo "validate $*" >> "$STATE/nono.log"
      exit "${STUB_NONO_VALIDATE_EXIT:-0}"
    fi
    exit 0
    ;;
  run)
    case "$*" in
      *--check-only*)
        # Keep-alive state AT the gate instant: the discriminating
        # evidence that the script stops it before the sandbox runs.
        if [ -f "$HOME/magpie/.keepalive.pid" ]; then
          echo alive >> "$STATE/keepalive_at_gate.txt"
        else
          echo dead >> "$STATE/keepalive_at_gate.txt"
        fi
        exit "${STUB_NONO_GATE_EXIT:-0}"
        ;;
      *runscripts=default.R*)
        # Full-run request: probe the keep-alive the same way, then
        # re-enact the inner bash -c payload so the stub Rscript
        # fakes the run folder + artifacts.
        if [ -f "$HOME/magpie/.keepalive.pid" ]; then
          echo alive >> "$STATE/keepalive_at_gate.txt"
        else
          echo dead >> "$STATE/keepalive_at_gate.txt"
        fi
        if [ "${STUB_FULLRUN_FAIL:-0}" = "1" ]; then exit 1; fi
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
  *getRversion*)
    if [ "${STUB_R_OLD:-0}" = "1" ]; then exit 1; fi
    exit 0
    ;;
  *install_tinytex*)
    d="$HOME/.TinyTeX/bin/x86_64-unknown-linux-gnu"
    mkdir -p "$d"
    printf '#!/bin/sh\necho stub-tex\n' > "$d/tex"
    chmod 755 "$d/tex"
    exit 0
    ;;
  *"install.packages"*) exit 0 ;;
  *requireNamespace*renv*) exit "${STUB_RENV_PKG_EXIT:-0}" ;;
  *"renv/activate.R"*) exit "${STUB_RENV_ACTIVATE_EXIT:-0}" ;;
  *"renv::restore"*)
    # A restore makes the project library loadable from then on.
    touch "$STATE/renv_restored"
    exit "${STUB_RENV_RESTORE_EXIT:-0}"
    ;;
  *"library(lucode2)"*)
    if [ -f "$STATE/renv_restored" ]; then exit 0; fi
    exit "${STUB_RENV_EXIT:-0}"
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
  # The banner text is env-switchable for the gams check table.
  cat > "$STATE/binlib/gams" <<'EOS'
#!/bin/sh
printf '%s\n' "${STUB_GAMS_BANNER:-GAMS 54.6.1 - The installed license is valid.}"
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
  # curl: feed POSTs (--data-binary) -> feed.log; archives -> state files.
  cat > "$FAKE_BIN/curl" <<'EOS'
#!/bin/sh
prev=""
out=""
url=""
post=0
for a in "$@"; do
  case $prev in -o) out=$a ;; esac
  case $a in http*|https*) url=$a ;; esac
  case $a in --data-binary) post=1 ;; esac
  prev=$a
done
if [ "$post" = "1" ]; then
  printf '%s\n' "$(cat)" >> "$STATE/feed.log"
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
  cat > "$FAKE_BIN/apt-get" <<'EOS'
#!/bin/sh
echo "apt-get $*" >> "$STATE/apt.log"
if [ "${STUB_APT_FAIL:-0}" = "1" ]; then exit 100; fi
seen_install=0
for a in "$@"; do [ "$a" = install ] && seen_install=1; done
if [ "$seen_install" = 1 ]; then
  for a in "$@"; do
    case $a in
      r-base) cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript" 2>/dev/null || true ;;
      pandoc) cp "$STATE/binlib/pandoc" "$FAKE_BIN/pandoc" 2>/dev/null || true ;;
    esac
  done
fi
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

  # Fake GAMS linux self-extractor: extracts a working gams stub.
  cat > "$STATE/archives/linux_x64_64_sfx.exe" <<'EOS'
#!/bin/sh
mkdir -p gams54.6.1_linux_x64_64_sfx
printf '#!/bin/sh\nprintf "%%s\\n" "${STUB_GAMS_BANNER:-GAMS 54.6.1 - The installed license is valid.}"\n' \
  > gams54.6.1_linux_x64_64_sfx/gams
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
  # Fixture: magpie master gitignores /renv.lock; the seed ships one so
  # the restore branches and the renv checks run in E2E.
  printf '%s\n' '{"R": {"Version": "4.4.0"}}' > "$ENV/seed/renv.lock"
  git -C "$ENV/seed" add README.md renv.lock >/dev/null
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
  # magpie_licence_available.
  sed '/^__PASTE_CONTENTS_OF_gamslice.txt_HERE__$/s|__PASTE_CONTENTS_OF_gamslice.txt_HERE__|TEST-LICENCE-CONTENT|' \
    "$ENV/magpie.sh" > "$ENV/magpie_lic.sh"
  chmod +x "$ENV/magpie_lic.sh"

  SRC="$SCRIPT"
  E2E_SCRIPT="$ENV/magpie.sh"
}

# Per-scenario clone of the template. cp -a = fresh inodes (scenarios
# mutate their own copies); cp -al for minbin = same hardlinks to host
# tools the old inline loop made, so exec behaviour is unchanged.
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
  cp -a "$TEMPLATE/state" "$STATE"
  cp -a "$TEMPLATE/bin/." "$FAKE_BIN/"
  cp -al "$TEMPLATE/minbin/." "$MINBIN/"
  cp -a "$TEMPLATE/magpie.sh" "$ENV/magpie.sh"
  cp -a "$TEMPLATE/magpie_lic.sh" "$ENV/magpie_lic.sh"
  SRC="$SCRIPT"
  E2E_SCRIPT="$ENV/magpie.sh"
}

base_env() {
  export HOME="$FAKE_HOME"
  export PATH="$FAKE_BIN:$MINBIN"
  export MAGPIE_RETRY_SECS=0 MAGPIE_RETRY_SECS2=0 MAGPIE_PASS_SECS=0
  export MAGPIE_KEEPALIVE_SECS=0.05 MAGPIE_SUDO_RETRY_SECS=0
  export MAGPIE_MAGPIE_URL="file://$STATE/origin.git"
  unset MAGPIE_SOURCED MAGPIE_SELF MAGPIE_PASS MAGPIE_PACK_FORCE
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
    mkdir -p "$FAKE_HOME/magpie"
    eval "$FN_BODY" </dev/null >> "$FAKE_HOME/magpie/setup-log.txt" 2>&1
  ) 4> "$STATE/screen.txt"
  RET=$?
}

# Tools that make the checks green (except renv: no lock = SKIP).
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


# A finished install (for rerun/clone-guard tests).
make_installed() {
  mkdir -p "$FAKE_HOME/.opencode/bin" "$FAKE_HOME/.nono/bin" \
    "$FAKE_HOME/.config/opencode" \
    "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode" \
    "$FAKE_HOME/magpie"
  git -C "$FAKE_HOME/magpie" init -q
  git -C "$FAKE_HOME/magpie" remote add origin "file://$STATE/origin.git"
  git -C "$FAKE_HOME/magpie" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m init
  cp "$STATE/binlib/opencode" "$FAKE_HOME/.opencode/bin/opencode"
  cp "$STATE/binlib/nono" "$FAKE_HOME/.nono/bin/nono"
  chmod 755 "$FAKE_HOME/.opencode/bin/opencode" "$FAKE_HOME/.nono/bin/nono"
  echo '{"model":"hu/llm3"}' > "$FAKE_HOME/.config/opencode/opencode.json"
  echo '{"name":"opencode","version":"9.9.9"}' > "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
}

map_target
build_template

# ============================================================
sec "syntax"
# ============================================================
if bash -n "$SCRIPT" 2>/dev/null; then ok "bash -n"; else no "bash -n"; fi
if command -v dash >/dev/null 2>&1; then
  if dash -n "$SCRIPT" 2>/dev/null; then ok "dash -n"; else no "dash -n"; fi
else
  echo "  (dash not installed - skipped)"
fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s sh "$SCRIPT" >/dev/null 2>&1; then ok "shellcheck"; else no "shellcheck"; fi
else
  echo "  (shellcheck not installed - skipped)"
fi

# ============================================================
sec "placeholder pin guard"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; R_SHA256_DARWIN_X64=TBD; magpie_require_pins' run_fn
ret_is "pins TBD aborts" 1
grep_ok "help block shown" "$STATE/screen.txt" "script incomplete: pinned versions/checksums missing"
nofile_ok "no lock created" "$FAKE_HOME/magpie/.setup.lock"
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

# ============================================================
sec "root guard"
# ============================================================
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_setup_path' \
  run_fn STUB_ID_ROOT=1
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
# The second window must NOT clean the FIRST run's state: no deletion
# of its setup-dl-* downloads, no kill of its keep-alive.
new_env
mkdir -p "$FAKE_HOME/magpie/.setup.lock"
sleep 60 &
LIVEPID=$!
echo "$LIVEPID" > "$FAKE_HOME/magpie/.setup.lock/pid"
sleep 60 &
KPID=$!
echo "$KPID" > "$FAKE_HOME/magpie/.keepalive.pid"
touch "$FAKE_HOME/magpie/setup-dl-gams.exe"
FN_BODY='magpie_take_lock' run_fn
kill "$LIVEPID" 2>/dev/null
ret_is "second window exits 0 quietly" 0
file_ok "first run download untouched" "$FAKE_HOME/magpie/setup-dl-gams.exe"
file_ok "first run keepalive pidfile untouched" "$FAKE_HOME/magpie/.keepalive.pid"
if [ -n "$KPID" ] && kill -0 "$KPID" 2>/dev/null; then ok "first run keepalive not killed"; else no "first run keepalive not killed"; fi
kill "$KPID" 2>/dev/null

# ============================================================
sec "cold fail path (before MAGPIE_OS is set)"
# ============================================================
# The entry mkdir failure calls magpie_fail before magpie_main has
# set MAGPIE_OS - the help block's System line must still be filled.
new_env
EXPECT_SYS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f 2)
FN_BODY='magpie_sys_string' run_fn
ret_is "system string survives unset MAGPIE_OS" 0
grep_ok "system string reports the distro" "$FAKE_HOME/magpie/setup-log.txt" "$EXPECT_SYS"

# ============================================================
sec "retry helper + pass-2 model"
# ============================================================
new_env
FN_BODY='flaky() { c="$STATE/f"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$c"; [ "$n" -gt 2 ]; }; magpie_retry 3 flaky' run_fn
ret_is "2 fails then success" 0
new_env
FN_BODY='alwaysfail() { return 1; }; magpie_retry 3 alwaysfail' run_fn
ret_is "persistent fail returns 1" 1
grep_ok "3 attempts logged" "$FAKE_HOME/magpie/setup-log.txt" "attempt 3/3"
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
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; MAGPIE_PASS=2 magpie_step_failed teststep' \
  run_fn
ret_is "pass 2 failure blocks" 1
grep_ok "help block after pass 2" "$STATE/screen.txt" "##"
grep_ok "failed step named" "$STATE/screen.txt" "FAILED STEP (twice, reproducible): teststep"
grep_ok "code name in help block" "$STATE/screen.txt" "code name: T1"

# ============================================================
sec "sudo loop + keep-alive"
# ============================================================
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0 STUB_SUDO_V_FAILS=4
ret_is "sudo succeeds after 4 bad tries" 0
cnt_is "retry line 4x" "Password not accepted" "$STATE/screen.txt" 4
grep_no "no help block" "$STATE/screen.txt" "##"
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0 STUB_SUDO_V_FAILS=99
ret_is "sudo cap blocks" 1
grep_ok "help block at cap" "$STATE/screen.txt" "##"
cnt_is "6 rounds" "Password not accepted" "$STATE/screen.txt" 6
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=1
ret_is "warm timestamp no prompt" 0
grep_no "no prompt line" "$STATE/screen.txt" "asked now"
nofile_ok "keepalive only after ask" "$FAKE_HOME/magpie/.keepalive.pid"
new_env
FN_BODY='MAGPIE_HANDLE=T1; magpie_take_lock; magpie_sudo_warm' run_fn STUB_SUDO_N_OK=0
ret_is "prompt starts keepalive" 0
grep_ok "prompt line" "$STATE/screen.txt" "Type it blind"
wait_gone "$FAKE_HOME/magpie/.keepalive.pid"
nofile_ok "owner exit stops keepalive + removes pidfile" "$FAKE_HOME/magpie/.keepalive.pid"
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
nofile_ok "keepalive pidfile gone" "$FAKE_HOME/magpie/.keepalive.pid"
grep_ok "gate args: profile" "$STATE/nono.log" "--profile magpie-profile"
grep_ok "gate args: check-only child" "$STATE/nono.log" "--check-only"
grep_ok "gate args: env switch" "$STATE/nono.log" "MAGPIE_CHECK_ONLY=1"
grep_ok "gate args: madrat cache passed" "$STATE/nono.log" "MADRAT_CACHE="
grep_ok "gate args: renv cache passed" "$STATE/nono.log" "RENV_PATHS_CACHE="

# ============================================================
sec "cache folders + rc lines"
# ============================================================
new_env
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_register_caches; magpie_register_caches' run_fn
ret_is "caches registered" 0
file_ok "madrat dir created" "$FAKE_HOME/.madrat"
file_ok "renv cache dir created" "$FAKE_HOME/.cache/R/renv"
cnt_is "MADRAT rc line deduped" "MADRAT_CACHE" "$FAKE_HOME/.bashrc" 1
cnt_is "RENV rc line deduped" "RENV_PATHS_CACHE" "$FAKE_HOME/.bashrc" 1

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
wait_file "$FAKE_HOME/magpie/.keepalive.pid"
wait_file "$FAKE_HOME/magpie/.setup.lock/pid"
kp=$(cat "$FAKE_HOME/magpie/.keepalive.pid" 2>/dev/null || echo "")
kill -TERM "$tp" 2>/dev/null
wait "$tp" 2>/dev/null
rc=$?
[ -n "$kp" ] && ok "keepalive was running" || no "keepalive was running"
[ "$rc" = 130 ] && ok "exit code 130 on TERM" || no "exit code 130 on TERM (got $rc)"
nofile_ok "lock removed" "$FAKE_HOME/magpie/.setup.lock"
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

# ============================================================
sec "handle (code name)"
# ============================================================
new_env
FN_BODY='magpie_init_handle' run_fn
file_ok "handle file created" "$FAKE_HOME/.magpie-course-handle"
h=$(cat "$FAKE_HOME/.magpie-course-handle" 2>/dev/null)
case $h in
  [A-Z][a-z]*[0-9][0-9][0-9]) ok "handle format: Animal+3digits ($h)" ;;
  *) no "handle format: Animal+3digits ($h)" ;;
esac
grep_ok "NOTE IT DOWN box on first creation" "$STATE/screen.txt" "NOTE IT DOWN"
new_env
echo "Fox123" > "$FAKE_HOME/.magpie-course-handle"
FN_BODY='magpie_greet' run_fn
grep_ok "greet reuses handle" "$STATE/screen.txt" "Reporting status as Fox123"
grep_no "no box on reuse" "$STATE/screen.txt" "NOTE IT DOWN"

# ============================================================
sec "config write"
# ============================================================
new_env
CFG="$FAKE_HOME/.config/opencode/opencode.json"
FN_BODY='magpie_os_placeholder=1; magpie_write_opencode_config' run_fn
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

# ============================================================
sec "HU key rc line"
# ============================================================
new_env
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_register_hu_key' run_fn
ret_is "hu key registered" 0
FN_BODY='MAGPIE_RC="$HOME/.bashrc"; magpie_register_hu_key' run_fn
cnt_is "rc line stays deduped" "HU_API_KEY" "$FAKE_HOME/.bashrc" 1

# ============================================================
sec "licence: placeholder / pasted / never-clobber / darwin"
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
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "placeholder blocks the write" 1
nofile_ok "nothing written" "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
new_env
SRC="$ENV/magpie_lic.sh"
mkdir -p "$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "pasted licence writes" 0
T="$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
grep_ok "licence content" "$T" "TEST-LICENCE-CONTENT"
mode_is "licence mode 600" "$T" 600
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
grep_ok "rerun: already in place" "$FAKE_HOME/magpie/setup-log.txt" "already in place"
echo "OLD" > "$T"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
grep_ok "existing file never clobbered" "$T" "OLD"
new_env
SRC="$ENV/magpie_lic.sh"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1; magpie_install_licence' run_fn
ret_is "darwin licence writes" 0
T="$FAKE_HOME/Library/Application Support/GAMS/gamslice.txt"
grep_ok "darwin licence content" "$T" "TEST-LICENCE-CONTENT"
mode_is "darwin licence mode 600" "$T" 600
mode_is "darwin licence dir mode 700" "$(dirname "$T")" 700

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
grep_ok "renv SKIP line" "$STATE/screen.txt" "SKIP renv check"
grep_ok "check result fed" "$STATE/feed.log" "check result"
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "all stubs green -> PASS" 0
grep_ok "gams GAMS54 wording PASS" "$STATE/screen.txt" "PASS gams"
grep_ok "git PASS" "$STATE/screen.txt" "PASS git"
grep_ok "R PASS" "$STATE/screen.txt" "PASS R 4.4.2"
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
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn STUB_R_OLD=1
ret_is "old R FAILs" 1
grep_ok "R version line" "$STATE/screen.txt" "FAIL R older than 4.3"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
touch "$FAKE_HOME/magpie/renv.lock"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "renv.lock green library PASS" 0
grep_ok "renv PASS" "$STATE/screen.txt" "PASS renv R library"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
touch "$FAKE_HOME/magpie/renv.lock"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn STUB_RENV_EXIT=1
ret_is "renv.lock broken library FAIL" 1
grep_ok "renv FAIL" "$STATE/screen.txt" "FAIL renv R library incomplete"

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
grep_ok "result block on screen" "$STATE/screen.txt" "end of copy block"
nofile_ok "no lock in child" "$FAKE_HOME/magpie/.setup.lock"
nofile_ok "no log tee in child" "$FAKE_HOME/magpie/setup-log.txt"
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

# ============================================================
sec "TinyTeX step: skip only with real tex, half dir heals"
# ============================================================
new_env
cp "$STATE/binlib/Rscript" "$FAKE_BIN/Rscript"
mkdir -p "$FAKE_HOME/.TinyTeX/share"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_tinytex' \
  run_fn
ret_is "half TinyTeX dir reinstall heals" 0
grep_ok "half dir logged" "$FAKE_HOME/magpie/setup-log.txt" "incomplete"
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

# ============================================================
sec "nono profile: pull + magpie-profile build"
# ============================================================
new_env
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_pull_nono_profile' run_fn
ret_is "pack pulled at pin" 0
grep_ok "pull carries the pin" "$STATE/nono.log" "pull nolabs-ai/opencode@9.9.9"
grep_ok "pack pinned" "$STATE/nono.log" "nono pin nolabs-ai/opencode"
new_env
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "profile built" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
file_ok "profile file exists" "$PJSON"
grep_ok "extends opencode" "$PJSON" '"extends": \["opencode"\]'
grep_ok "linux read list holds gams" "$PJSON" "$FAKE_HOME/gams"
grep_ok "linux read list holds TinyTeX" "$PJSON" "$FAKE_HOME/.TinyTeX"
grep_ok "validate called" "$STATE/nono.log" "profile validate"
new_env
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "linux profile has cache write paths" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "write section present" "$PJSON" '"write"'
grep_ok "write holds madrat" "$PJSON" "$FAKE_HOME/.madrat"
grep_ok "write holds renv cache" "$PJSON" ".cache/R/renv"
grep_ok "read holds madrat too" "$PJSON" "$FAKE_HOME/.madrat"
new_env
put_nono
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "darwin profile built" 0
PJSON="$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
grep_ok "darwin keeps gams framework read" "$PJSON" "/Library/Frameworks/GAMS.framework"
grep_ok "darwin keeps gfortran read" "$PJSON" "/usr/local/gfortran"
grep_ok "darwin write section present" "$PJSON" '"write"'
grep_ok "darwin write holds madrat" "$PJSON" "$FAKE_HOME/.madrat"
grep_ok "darwin write holds renv cache" "$PJSON" ".cache/R/renv"
new_env
mkdir -p "$FAKE_HOME/.config/nono/profiles"
echo "changed by student" > "$FAKE_HOME/.config/nono/profiles/magpie-profile.json"
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_magpie_profile' run_fn
ret_is "modified profile kept" 0
grep_ok "modified file untouched" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" "changed by student"
new_env
make_tools
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
magpie_step_magpie_profile' run_fn STUB_NONO_VALIDATE_EXIT=1
ret_is "validate failure blocks (2 passes)" 1
grep_ok "profile step named in help" "$STATE/screen.txt" \
  "FAILED STEP (twice, reproducible): magpie-profile build"
new_env
make_installed
sed -i 's|"version":"9.9.9"|"version":"8.8.8"|' "$FAKE_HOME/.config/nono/packages/nolabs-ai/opencode/package.json"
put_nono
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_pull_nono_profile' run_fn
ret_is "drift force re-pulls" 0
grep_ok "force pull at pin" "$STATE/nono.log" "pull force=1 ref=nolabs-ai/opencode@9.9.9"

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
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' run_fn
ret_is "gfortran skip when present" 0
nofile_ok "no pkg download" "$STATE/curl.log"
grep_no "no installer call" "$STATE/installer.log" "installer"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' run_fn
ret_is "gfortran pkg installs" 0
grep_ok "installer -pkg called" "$STATE/installer.log" "installer -pkg"
grep_ok "gfortran pkg name" "$STATE/installer.log" "setup-dl-gfortran.pkg"
grep_ok "installer via sudo" "$STATE/sudo.log" "sudo installer -pkg"
grep_ok "OK line" "$STATE/screen.txt" "OK: gfortran installed"
file_ok "gfortran now on PATH" "$FAKE_BIN/gfortran"
nofile_ok "setup-dl pkg removed" "$FAKE_HOME/magpie/setup-dl-gfortran.pkg"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_HANDLE=T1
MAGPIE_PKG_URL=$GFORTRAN_URL; MAGPIE_PKG_SHA=$GFORTRAN_SHA256; magpie_gfortran_body' \
  run_fn STUB_BAD_ARCHIVE=1
ret_is "gfortran checksum mismatch blocks" 1
nofile_ok "installer never called" "$STATE/installer.log"
nofile_ok "no sudo before verify" "$STATE/sudo.log"
nofile_ok "no pkg left behind" "$FAKE_HOME/magpie/setup-dl-gfortran.pkg"
# Off-PATH pkg target: the dir must land in rc + this run's PATH, or
# renv restore compiles fail and sandboxed children never see gfortran.
new_env
mkdir -p "$FAKE_HOME/local/bin"
cp "$STATE/binlib/gfortran" "$FAKE_HOME/local/bin/gfortran"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/local"
ret_is "gfortran off-PATH present skips + registers" 0
nofile_ok "no pkg download" "$STATE/curl.log"
grep_ok "rc gfortran dir line" "$FAKE_HOME/.zshrc" "$FAKE_HOME/local/bin"
grep_ok "gfortran registered log" "$FAKE_HOME/magpie/setup-log.txt" "gfortran registered"
new_env
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_gfortran' \
  run_fn MAGPIE_GFORTRAN_DIR="$FAKE_HOME/local" STUB_GF_TARGET="$FAKE_HOME/local/bin"
ret_is "gfortran pkg install registers off-PATH dir" 0
grep_ok "installer -pkg called" "$STATE/installer.log" "installer -pkg"
grep_ok "OK: gfortran installed" "$STATE/screen.txt" "OK: gfortran installed"
grep_ok "rc gfortran dir line (install)" "$FAKE_HOME/.zshrc" "$FAKE_HOME/local/bin"
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
nofile_ok "gams pkg file removed" "$FAKE_HOME/magpie/setup-dl-gams.pkg"
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
nofile_ok "exe removed after extract" "$FAKE_HOME/magpie/setup-dl-gams.exe"
new_env
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_install_gams' \
  run_fn STUB_BAD_GAMS=1
ret_is "gams corrupt download blocks" 1
grep_ok "gams step named" "$STATE/screen.txt" "FAILED STEP (twice, reproducible): GAMS install"

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
sec "magpie clone guards"
# ============================================================
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
echo "mine" > "$FAKE_HOME/magpie/important.txt"
run_e2e
ret_is "foreign dir blocks" 1
grep_ok "foreign dir message" "$STATE/screen.txt" "not a magpie clone"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
echo "log" > "$FAKE_HOME/magpie/setup-log.txt"
echo "help" > "$FAKE_HOME/magpie/setup-help.txt"
run_e2e
ret_is "own files only -> clone proceeds" 0
file_ok "clone recreated .git" "$FAKE_HOME/magpie/.git"
grep_ok "clone happened" "$STATE/screen.txt" "OK: magpie cloned"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
touch "$FAKE_HOME/magpie/opencode-dl.tgz" "$FAKE_HOME/magpie/nono-dl.tar.gz"
touch "$FAKE_HOME/magpie/setup-dl-crashed.pkg"
mkdir -p "$FAKE_HOME/magpie/opencode-extract" "$FAKE_HOME/magpie/nono-extract"
run_e2e
ret_is "install leftovers (incl. setup-dl) -> clone proceeds" 0
file_ok "clone recreated .git" "$FAKE_HOME/magpie/.git"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
# magpie-opencode's finish marker is foreign state but tolerated (never
# written here - magpie_setup_path comment). The full run marker is
# own state and tolerated by the guard too (the run then FAILs later at
# the stale marker - proof: the clone itself proceeds).
printf '2026-01-01 00:00:00\nnono 0.81.0\nopencode 2.2.7\n' \
  > "$FAKE_HOME/magpie/.setup-finished"
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
run_e2e
ret_is "markers tolerated by guard, run fails on stale marker" 1
grep_no "no false foreign-dir abort" "$STATE/screen.txt" "not a magpie clone"
file_ok "clone recreated .git" "$FAKE_HOME/magpie/.git"
grep_ok "clone happened" "$STATE/screen.txt" "OK: magpie cloned"
grep_ok "stale marker FAIL line" "$STATE/screen.txt" "FAIL full run artifacts missing - rerun this file"
grep_ok "existing opencode marker kept untouched" "$FAKE_HOME/magpie/.setup-finished" "nono 0.81.0"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
git -C "$FAKE_HOME/magpie" init -q
git -C "$FAKE_HOME/magpie" remote add origin "file://$STATE/origin.git"
run_e2e
ret_is "interrupted clone healed on rerun" 0
grep_ok "heal logged" "$FAKE_HOME/magpie/setup-log.txt" "interrupted clone found"
grep_ok "clone checked out file" "$FAKE_HOME/magpie/README.md" "readme"
new_env
make_installed
rm -rf "$FAKE_HOME/magpie/.git"
git -C "$FAKE_HOME/magpie" init -q
git -C "$FAKE_HOME/magpie" remote add origin https://elsewhere.invalid/repo.git
run_e2e
ret_is "foreign origin in .git blocks" 1
grep_ok "foreign dir message" "$STATE/screen.txt" "not a magpie clone"
new_env
FN_BODY='mkdir -p "$HOME/magpie"; magpie_clone_body && magpie_clone_body' run_fn
ret_is "clone body idempotent twice" 0

# ============================================================
sec "renv restore step"
# ============================================================
# No renv.lock: skip quietly, no R calls.
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_renv_restore' run_fn
ret_is "no renv.lock skips quietly" 0
grep_no "no restore attempt" "$STATE/rscript.log" "renv"
grep_no "no heads-up when skipped" "$STATE/screen.txt" "installing"
# Library already loads: skip, restore never called.
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
touch "$FAKE_HOME/magpie/renv.lock"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_renv_restore' run_fn
ret_is "populated library skips restore" 0
grep_no "no restore call" "$STATE/rscript.log" "renv::restore"
grep_no "no heads-up when skipped" "$STATE/screen.txt" "installing"
# Load test fails: restore runs, verify passes, feed + OK line.
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
touch "$FAKE_HOME/magpie/renv.lock"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_renv_restore' \
  run_fn STUB_RENV_EXIT=1 STUB_RENV_PKG_EXIT=1
ret_is "broken library gets restored" 0
grep_ok "activate.R bootstrapped" "$STATE/rscript.log" "renv/activate.R"
grep_ok "restore called unprompted" "$STATE/rscript.log" "renv::restore(prompt = FALSE, restart = FALSE)"
grep_ok "restore heads-up" "$STATE/screen.txt" "installing renv library restore, about 5-15 min"
grep_ok "OK line" "$STATE/screen.txt" "OK: renv library restored"
grep_ok "restore fed" "$STATE/feed.log" "setup: renv restored"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
touch "$FAKE_HOME/magpie/renv.lock"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_renv_restore' \
  run_fn STUB_RENV_EXIT=1
grep_no "no bootstrap when renv present" "$STATE/rscript.log" "renv/activate.R"
grep_ok "restore still called" "$STATE/rscript.log" "renv::restore"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
touch "$FAKE_HOME/magpie/renv.lock"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 magpie_step_renv_restore' \
  run_fn STUB_RENV_EXIT=1 STUB_RENV_RESTORE_EXIT=1
ret_is "persistent restore failure blocks" 1
grep_ok "renv step named" "$STATE/screen.txt" "FAILED STEP (twice, reproducible): renv restore"
cnt_is "3 restore attempts" "renv::restore" "$STATE/rscript.log" 3

# ============================================================
sec "full run step"
# ============================================================
# Success path: sandbox command shape + marker + artifacts + feed.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' run_fn
ret_is "full run completes" 0
grep_ok "sandbox run via profile" "$STATE/nono.log" "run --profile magpie-profile -- env"
grep_ok "madrat cache passed" "$STATE/nono.log" "MADRAT_CACHE="
grep_ok "renv cache passed" "$STATE/nono.log" "RENV_PATHS_CACHE="
grep_ok "PATH passed" "$STATE/nono.log" "PATH="
grep_ok "bash -c payload" "$STATE/nono.log" "bash -c"
grep_ok "default run script selected" "$STATE/nono.log" "runscripts=default.R submit=direct"
grep_ok "R script invoked" "$STATE/rscript.log" "start.R runscripts=default.R submit=direct"
grep_ok "keep-alive dead at full run" "$STATE/keepalive_at_gate.txt" "dead"
grep_ok "40 min heads-up" "$STATE/screen.txt" "full magpie run, about 40 min"
grep_ok "OK line" "$STATE/screen.txt" "OK: full magpie run finished"
grep_ok "feed start" "$STATE/feed.log" "setup: full run start"
grep_ok "feed finished" "$STATE/feed.log" "setup: full run finished"
file_ok "marker written" "$FAKE_HOME/magpie/.setup-fullrun-ok"
grep_ok "marker names run folder" "$FAKE_HOME/magpie/.setup-fullrun-ok" \
  '^output/default_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}$'
RUNDIR=$(sed -n 1p "$FAKE_HOME/magpie/.setup-fullrun-ok")
file_ok "fulldata.gdx present" "$FAKE_HOME/magpie/$RUNDIR/fulldata.gdx"
file_ok "report.rds present" "$FAKE_HOME/magpie/$RUNDIR/report.rds"
# start.R update prompts are answered with two "n" lines on stdin, so
# the run never asks and never auto-updates (locked versions stay).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn STUB_FULLRUN_CAPTURE=1
ret_is "prompt-fed run completes" 0
cnt_is "two n answers reach Rscript" "^n$" "$STATE/fullrun_stdin" 2
# Verified marker: rerun skips without touching the sandbox.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' run_fn
ret_is "verified marker skips the run" 0
grep_no "no sandbox run" "$STATE/nono.log" "runscripts=default.R"
grep_no "no R run" "$STATE/rscript.log" "start.R"
grep_ok "skip logged" "$FAKE_HOME/magpie/setup-log.txt" "full run: marker verified"
grep_no "no heads-up on skip" "$STATE/screen.txt" "40 min"
# Non-zero sandbox exit: straight to the help block, no marker.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 magpie_step_full_run' run_fn STUB_FULLRUN_FAIL=1
ret_is "non-zero sandbox exit fails" 1
grep_ok "help block" "$STATE/screen.txt" "##"
grep_ok "step named" "$STATE/screen.txt" "FAILED STEP (twice, reproducible): full magpie run (check the run folder under ~/magpie)"
grep_ok "FAIL fed" "$STATE/feed.log" "setup: FAIL full magpie run"
nofile_ok "no marker on failure" "$FAKE_HOME/magpie/.setup-fullrun-ok"
# Exit 0 but swallowed run error (no output artifacts): artifacts fail it.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 magpie_step_full_run' run_fn STUB_FULLRUN_NO_OUTPUT=1
ret_is "missing postprocessing artifacts fail" 1
grep_ok "artifact failure named" "$STATE/screen.txt" "FAILED STEP (twice, reproducible): full magpie run (check the run folder under ~/magpie)"
nofile_ok "no marker without artifacts" "$FAKE_HOME/magpie/.setup-fullrun-ok"
grep_no "no finished feed line" "$STATE/feed.log" "setup: full run finished"
# An OLD complete run folder is not accepted as the NEW one (no-op run).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 magpie_step_full_run' run_fn STUB_FULLRUN_NOTHING=1
ret_is "old folder is not accepted as new" 1
nofile_ok "no marker without a new folder" "$FAKE_HOME/magpie/.setup-fullrun-ok"
# Non-zero inner Rscript exit despite COMPLETE artifacts: the exit code
# fails the step too (spec: non-zero sandbox exit fails regardless).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1
MAGPIE_PASS=2 magpie_step_full_run' run_fn STUB_FULLRUN_RSCRIPT_EXIT=1
ret_is "non-zero exit with complete artifacts fails" 1
grep_ok "exit-code failure named" "$STATE/screen.txt" "FAILED STEP (twice, reproducible): full magpie run (check the run folder under ~/magpie)"
nofile_ok "no marker on non-zero exit" "$FAKE_HOME/magpie/.setup-fullrun-ok"
grep_ok "exit-code FAIL fed" "$STATE/feed.log" "setup: FAIL full magpie run"
# An old complete folder plus a NEW complete folder: the marker names
# the NEWEST one (sort direction).
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' run_fn
ret_is "new folder wins over old complete one" 0
file_ok "marker written (newest wins)" "$FAKE_HOME/magpie/.setup-fullrun-ok"
grep_no "marker is not the old folder" "$FAKE_HOME/magpie/.setup-fullrun-ok" \
  "^output/default_2026-01-01_00\\.00\\.00$"
file_ok "old run folder untouched" \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00/fulldata.gdx"
# Escape hatch: MAGPIE_FULL_RUN=0 -> note + feed + return 0, no marker.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=linux; MAGPIE_RC="$HOME/.bashrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn MAGPIE_FULL_RUN=0
ret_is "escape hatch returns 0" 0
grep_ok "screen note" "$STATE/screen.txt" "Full run skipped (MAGPIE_FULL_RUN=0)"
grep_ok "feed note" "$STATE/feed.log" "setup: full run skipped (MAGPIE_FULL_RUN=0)"
nofile_ok "no marker written" "$FAKE_HOME/magpie/.setup-fullrun-ok"
grep_no "no sandbox run" "$STATE/nono.log" "runscripts=default.R"
# macOS: the whole call is wrapped in caffeinate -is.
new_env
make_tools
put_nono
mkdir -p "$FAKE_HOME/magpie"
FN_BODY='MAGPIE_OS=darwin; MAGPIE_RC="$HOME/.zshrc"; MAGPIE_HANDLE=T1; magpie_step_full_run' \
  run_fn STUB_FULLRUN_CAPTURE=1
ret_is "darwin full run through caffeinate" 0
grep_ok "caffeinate wraps the call" "$STATE/caffeinate.log" "caffeinate -is nono run --profile magpie-profile"
file_ok "marker written (darwin)" "$FAKE_HOME/magpie/.setup-fullrun-ok"
cnt_is "prompt answers survive caffeinate" "^n$" "$STATE/fullrun_stdin" 2

# ============================================================
sec "full run check line"
# ============================================================
new_env
make_tools
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
grep_ok "first run must not FAIL" "$STATE/screen.txt" "SKIP full run (starts at the end of this setup)"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"
touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
  "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "marker + artifacts PASS" 0
grep_ok "PASS line" "$STATE/screen.txt" "PASS full run (output/default_2026-01-01_00.00.00)"
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
ret_is "stale marker FAILs" 1
grep_ok "FAIL line" "$STATE/screen.txt" "FAIL full run artifacts missing - rerun this file"
# Each single artifact alone makes a folder-with-marker FAIL the check.
for artifact in fulldata.gdx full.lst report.rds report.mif; do
  new_env
  make_tools
  mkdir -p "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"
  touch "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/fulldata.gdx \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/full.lst \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.rds \
    "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00"/report.mif
  rm "$FAKE_HOME/magpie/output/default_2026-01-01_00.00.00/$artifact"
  printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
  FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn
  ret_is "missing $artifact alone FAILs the check" 1
done
new_env
make_tools
mkdir -p "$FAKE_HOME/magpie"
printf 'output/default_2026-01-01_00.00.00\n' > "$FAKE_HOME/magpie/.setup-fullrun-ok"
FN_BODY='MAGPIE_OS=linux; MAGPIE_HANDLE=T1; magpie_run_checks' run_fn MAGPIE_FULL_RUN=0
ret_is "escape hatch check SKIPs" 0
grep_ok "SKIP via env line" "$STATE/screen.txt" "SKIP full run (skipped via MAGPIE_FULL_RUN=0)"

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
grep_ok "apt tools OK line" "$S" "OK: apt course tools installed"
grep_ok "TinyTeX OK line" "$S" "OK: TinyTeX installed"
grep_ok "GAMS OK line" "$S" "OK: GAMS 54.6.1 installed"
grep_ok "licence written line" "$S" "Course licence written"
grep_ok "profile pull OK line" "$S" "OK: nono profile opencode pulled"
grep_ok "magpie-profile OK line" "$S" "OK: nono profile magpie-profile in place"
grep_ok "clone OK line" "$S" "OK: magpie cloned"
cnt_is "exactly 7 heads-ups" "installing" "$S" 7
grep_no "apt skipped no heads-up" "$S" "apt update"
grep_no "no help block" "$S" "##"
grep_ok "NOTE IT DOWN on first run" "$S" "NOTE IT DOWN"
grep_no "no blind sudo prompt" "$S" "Type it blind"
grep_ok "all checks PASS" "$S" "PASS gams"
grep_ok "check block printed" "$S" "end of copy block"
grep_ok "renv PASS (lock in clone, loads)" "$S" "PASS renv R library"
grep_ok "full run SKIP before step" "$S" "SKIP full run (starts at the end of this setup)"
grep_ok "full run heads-up" "$S" "full magpie run, about 40 min"
grep_ok "full run OK line" "$S" "OK: full magpie run finished"
grep_ok "next steps: full run done" "$S" "Full default run: done ->"
grep_ok "next steps: own scenario" "$S" "Rscript start.R"
grep_no "no manual renv line" "$S" "Rscript -e 'renv::restore()'"
grep_no "old rerun-setup hint gone" "$S" "rerun this setup file"
# feed protocol
grep_ok "feed start" "$STATE/feed.log" "setup: start"
grep_ok "feed check result block" "$STATE/feed.log" "check result"
grep_ok "feed PASS gams line" "$STATE/feed.log" "PASS gams"
grep_ok "feed full run start" "$STATE/feed.log" "setup: full run start"
grep_ok "feed full run finished" "$STATE/feed.log" "setup: full run finished"
grep_ok "feed run finished" "$STATE/feed.log" "setup: run finished"
grep_no "no FAIL on the feed" "$STATE/feed.log" "FAIL"
# state on disk
file_ok "clone checked out" "$FAKE_HOME/magpie/README.md"
file_ok "log under ~/magpie" "$FAKE_HOME/magpie/setup-log.txt"
nofile_ok ".setup-finished never written" "$FAKE_HOME/magpie/.setup-finished"
nofile_ok "lock released" "$FAKE_HOME/magpie/.setup.lock"
nofile_ok "no setup-dl leftovers" "$FAKE_HOME/magpie/setup-dl-gams.exe"
ls "$FAKE_HOME/magpie" | grep -q '^setup-dl-' && no "no setup-dl-* leftovers" || ok "no setup-dl-* leftovers"
T="$FAKE_HOME/gams/gams54.6.1_linux_x64_64_sfx/gamslice.txt"
grep_ok "licence in gams dir" "$T" "TEST-LICENCE-CONTENT"
mode_is "licence mode 600" "$T" 600
grep_ok "profile json read list has gams" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" "$FAKE_HOME/gams"
cnt_is "rc dedupe opencode" ".opencode/bin" "$FAKE_HOME/.bashrc" 1
cnt_is "rc dedupe nono" ".nono/bin" "$FAKE_HOME/.bashrc" 1
cnt_is "rc HU key once" "HU_API_KEY" "$FAKE_HOME/.bashrc" 1
grep_ok "rc gams dir line" "$FAKE_HOME/.bashrc" "gams54.6.1_linux_x64_64_sfx"
grep_ok "rc texbin line" "$FAKE_HOME/.bashrc" ".TinyTeX/bin"
grep_ok "tex registered" "$FAKE_HOME/magpie/setup-log.txt" "TinyTeX registered"
grep_ok "pull pinned" "$STATE/nono.log" "pull nolabs-ai/opencode@9.9.9"
grep_ok "gate ran" "$STATE/nono.log" "--profile magpie-profile"
grep_ok "keep-alive dead at gate" "$STATE/keepalive_at_gate.txt" "dead"
grep_no "no sudo -v (all silent)" "$STATE/sudo.log" "sudo -v"
file_ok "full run marker" "$FAKE_HOME/magpie/.setup-fullrun-ok"
RUNREL=$(sed -n 1p "$FAKE_HOME/magpie/.setup-fullrun-ok" 2>/dev/null)
file_ok "marker folder holds fulldata.gdx" "$FAKE_HOME/magpie/$RUNREL/fulldata.gdx"
file_ok "marker folder holds report.rds" "$FAKE_HOME/magpie/$RUNREL/report.rds"
file_ok "madrat cache dir created" "$FAKE_HOME/.madrat"
file_ok "renv cache dir created" "$FAKE_HOME/.cache/R/renv"
cnt_is "rc MADRAT line once" "MADRAT_CACHE" "$FAKE_HOME/.bashrc" 1
cnt_is "rc RENV line once" "RENV_PATHS_CACHE" "$FAKE_HOME/.bashrc" 1
grep_ok "profile write list holds madrat" "$FAKE_HOME/.config/nono/profiles/magpie-profile.json" "$FAKE_HOME/.madrat"

# second run: everything skips
run_e2e
ret_is "second run exits 0" 0
cnt_is "all steps skip (0 heads-ups)" "installing" "$STATE/screen.txt" 0
grep_no "handle box not repeated" "$STATE/screen.txt" "NOTE IT DOWN"
cnt_is "rc lines stay deduped" ".opencode/bin" "$FAKE_HOME/.bashrc" 1
grep_ok "licence already in place" "$FAKE_HOME/magpie/setup-log.txt" "already in place"
cnt_is "feed start twice over two runs" "setup: start" "$STATE/feed.log" 2
grep_ok "second run also finished" "$FAKE_HOME/magpie/setup-log.txt" "magpie: already cloned"
grep_ok "second run checks full run PASS" "$STATE/screen.txt" "PASS full run (output/default_"
grep_ok "second run skipped the run" "$FAKE_HOME/magpie/setup-log.txt" "full run: marker verified"
cnt_is "start.R ran once over two runs" "runscripts=default.R" "$STATE/rscript.log" 1

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
nofile_ok "pidfile gone after run" "$FAKE_HOME/magpie/.keepalive.pid"
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
grep_ok "next steps: skipped note" "$STATE/screen.txt" "Full default run: skipped (MAGPIE_FULL_RUN=0)"
grep_ok "still run finished" "$STATE/feed.log" "setup: run finished"
nofile_ok "no marker written" "$FAKE_HOME/magpie/.setup-fullrun-ok"
grep_no "no start.R invocation" "$STATE/rscript.log" "runscripts=default.R"

# ============================================================
sec "E2E deleted artifacts -> FAIL -> marker removal heals"
# ============================================================
new_env
E2E_SCRIPT="$ENV/magpie_lic.sh"
run_e2e
ret_is "green first" 0
RUNREL=$(sed -n 1p "$FAKE_HOME/magpie/.setup-fullrun-ok")
rm -rf "$FAKE_HOME/magpie/$RUNREL"
run_e2e
ret_is "missing artifacts block the rerun" 1
grep_ok "full run FAIL line" "$STATE/screen.txt" "FAIL full run artifacts missing - rerun this file"
grep_ok "help block" "$STATE/screen.txt" "##"
grep_ok "FAIL fed" "$STATE/feed.log" "setup: FAIL checks"
# Recovery: delete the marker, the step redoes the run.
rm -f "$FAKE_HOME/magpie/.setup-fullrun-ok"
run_e2e
ret_is "heals after marker removal" 0
grep_ok "SKIP line again" "$STATE/screen.txt" "SKIP full run (starts at the end of this setup)"
file_ok "marker rewritten" "$FAKE_HOME/magpie/.setup-fullrun-ok"
RUNREL=$(sed -n 1p "$FAKE_HOME/magpie/.setup-fullrun-ok")
file_ok "new run folder complete" "$FAKE_HOME/magpie/$RUNREL/report.mif"

# ============================================================
sec "E2E reproducible failure -> pass 2 -> help block"
# ============================================================
new_env
run_e2e STUB_BAD_ARCHIVE=1
ret_is "corrupt download blocks" 1
S="$STATE/screen.txt"
grep_ok "help block" "$S" "##"
grep_ok "failed step named" "$S" "FAILED STEP (twice, reproducible): opencode install"
grep_ok "wifi hint" "$S" "Wi-Fi"
grep_ok "code name in help block" "$S" "code name:"
cnt_is "retry heads-up once per pass" "retrying automatically" "$S" 1
cnt_is "failing step logged in both passes" "step failed after retries" "$FAKE_HOME/magpie/setup-log.txt" 2
grep_ok "FAIL line on the feed" "$STATE/feed.log" "setup: FAIL opencode install"
grep_no "run not finished" "$STATE/feed.log" "run finished"
nofile_ok "no lock left behind" "$FAKE_HOME/magpie/.setup.lock"
ls "$FAKE_HOME/magpie" | grep -q '^setup-dl-' && no "crash leaves no setup-dl-*" || ok "crash leaves no setup-dl-*"
file_ok "help file saved" "$FAKE_HOME/magpie/setup-help.txt"
new_env
run_e2e STUB_CURL_DL_FAILS=1
ret_is "transient download failure heals" 0
grep_no "no failure heads-up" "$STATE/screen.txt" "retrying automatically"

# ============================================================
printf '\n========================================\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_N" "$FAIL_N"
[ "$FAIL_N" = 0 ] || exit 1
exit 0
