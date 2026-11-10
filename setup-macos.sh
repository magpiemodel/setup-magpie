#!/usr/bin/env bash
# MAgPIE course setup for macOS. Standalone, safe to rerun.

# ============================================================
# TEACHER SECTION - edit only here before distributing
# ============================================================

# Live status feed. Set to "" to disable all uploading.
STATUS_URL="https://ntfy.sh/magpie-course-cb3363c15a75"

# Disk space: warn below WARN GB, hard stop below ABORT GB.
DISK_WARN_GB=15
DISK_ABORT_GB=6

GAMS_VERSION="54.6.1"
GAMS_URL_ARM64="https://d37drm4t2jghv5.cloudfront.net/distributions/${GAMS_VERSION}/macosx_arm64/GAMS${GAMS_VERSION}.pkg"
GAMS_SHA256_ARM64="0cb71b9682952afac7a203bdad310c1090765435f4d92960ae680c029ed1223b"
GAMS_URL_X86="https://d37drm4t2jghv5.cloudfront.net/distributions/${GAMS_VERSION}/macosx/GAMS${GAMS_VERSION}.pkg"
GAMS_SHA256_X86="f02a339236ad969abe6e161eda0ee39422360d33249ab9d15fa667ce191e8276"

# Paste the course gamslice.txt between the two COURSE_GAMSLICE lines.
magpie_licence_text() {
  cat <<'COURSE_GAMSLICE'
__PASTE_CONTENTS_OF_gamslice.txt_HERE__
COURSE_GAMSLICE
}

# ============================================================
# END TEACHER SECTION
# ============================================================

set -u

MAGPIE_HANDLE_FILE="$HOME/.magpie-course-handle"

magpie_init_handle() {
  if [ -f "$MAGPIE_HANDLE_FILE" ]; then
    MAGPIE_HANDLE=$(cat "$MAGPIE_HANDLE_FILE")
    return
  fi
  local animals a n
  animals=(Fox Otter Zebra Gecko Panda Koala Walrus Lynx Heron Bison \
    Mantis Puffin Cobra Yak Lemur Impala Orca Badger Falcon Manatee \
    Tapir Sloth Okapi Pangolin Narwhal Coyote Ibex Quokka Dingo Gibbon \
    Tarsier Jerboa Kestrel Marmot Ocelot Platypus Rhea Urchin Vulture \
    Wombat Toad Crane Hare Eagle Snake Turtle Parrot Hedgehog Beaver \
    Llama Alpaca Toucan Pelican Ferret)
  a=${animals[$((RANDOM % ${#animals[@]}))]}
  n=$((100 + RANDOM % 900))
  MAGPIE_HANDLE="$a$n"
  printf '%s\n' "$MAGPIE_HANDLE" > "$MAGPIE_HANDLE_FILE"
  echo
  echo "====================================================="
  echo "Your setup status is reported under the name: $MAGPIE_HANDLE"
  echo "NOTE IT DOWN (paper or phone)."
  echo "The course team will call out this name in the room."
  echo "Press Enter below once you noted the name."
  echo "====================================================="
  echo
  read -r _ < /dev/tty || true
  echo
}

magpie_greet() {
  magpie_init_handle
  echo "Reporting status as $MAGPIE_HANDLE."
}

magpie_report() {
  if [ -z "$STATUS_URL" ] || ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  magpie_init_handle
  printf '%s' "$MAGPIE_HANDLE | $(uname -s) $(uname -m) | $1" \
    | curl -m 5 -s -o /dev/null --data-binary @- "$STATUS_URL" || true
  return 0
}

# Appends the dir to the rc PATH line once and exports it into this run too.
magpie_rc_add_path() {
  local rc="$1" dir="$2" added=1
  touch "$rc"
  if ! grep -qF "$dir" "$rc"; then
    printf 'export PATH="%s:$PATH"\n' "$dir" >> "$rc"
    added=0
  fi
  export PATH="$dir:$PATH"
  return "$added"
}

magpie_fix_bin_path() {
  local rc="$HOME/.zshrc" bin dir found
  for bin in opencode nono; do
    if command -v "$bin" >/dev/null 2>&1; then
      continue
    fi
    found=0
    for dir in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/.nono/bin" /usr/local/bin; do
      if [ -x "$dir/$bin" ]; then
        if magpie_rc_add_path "$rc" "$dir"; then
          echo "Added $bin to PATH in $rc (also active in this run)."
        fi
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "NOTE: $bin was not found in the usual folders. Tell the TA."
      magpie_report "setup: $bin binary not found in usual folders"
    fi
  done
}

magpie_check_disk() {
  local free_gb
  free_gb=$(( $(df -Pk "$HOME" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if [ "$free_gb" -lt "$DISK_ABORT_GB" ]; then
    echo "Only $free_gb GB disk free - not enough (absolute minimum is $DISK_ABORT_GB GB)."
    echo "Empty the Trash and delete big files, then rerun this file."
    magpie_report "setup: FAIL low disk ${free_gb}G"
    exit 1
  fi
  if [ "$free_gb" -lt "$DISK_WARN_GB" ]; then
    echo "WARNING: only $free_gb GB disk free - MAgPIE needs about $DISK_WARN_GB GB."
    echo "Free space now (empty Trash, delete big downloads), then continue."
    magpie_report "setup: WARNING low disk ${free_gb}G"
  else
    echo "Disk space OK: $free_gb GB free."
  fi
}

magpie_sudo_keep() {
  sudo -n true || sudo -v
}

magpie_opencode_config() {
  local file="$HOME/.config/opencode/opencode.json" tmp
  mkdir -p "$HOME/.config/opencode"
  tmp=$(mktemp)
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
    echo "opencode config already in place."
    rm -f "$tmp"
    return
  fi
  if [ -f "$file" ]; then
    cp "$file" "$file.bak"
    echo "Existing opencode config saved as $file.bak"
  fi
  mv "$tmp" "$file"
  echo "Wrote opencode config: $file"
}

magpie_install_agents() {
  if command -v opencode >/dev/null 2>&1 || [ -x "$HOME/.opencode/bin/opencode" ]; then
    echo "opencode: already installed."
  else
    echo "Installing opencode..."
    if curl -fsSL https://opencode.ai/v2/install | bash; then
      echo "opencode installed."
      magpie_report "setup: opencode installed"
    else
      echo "opencode install failed - tell the TA."
      magpie_report "setup: FAIL opencode install"
    fi
  fi

  if command -v nono >/dev/null 2>&1; then
    echo "nono: already installed."
    return
  fi
  echo "Installing nono with Homebrew (a minute)..."
  if brew install nono; then
    echo "nono installed."
    magpie_report "setup: nono installed"
  else
    echo "nono install failed - tell the TA."
    magpie_report "setup: FAIL nono brew install"
  fi
}

# First macOS data dir GAMS searches for gamslice.txt (see GAMS docs).
magpie_licence_dir() {
  printf '%s\n' "$HOME/Library/Application Support/GAMS"
}

# True when the teacher pasted the licence text into this script.
magpie_licence_available() {
  local marker tmp
  marker="__PASTE_CONTENTS_OF_gamslice.txt_HERE__"
  tmp=$(mktemp)
  magpie_licence_text > "$tmp"
  if grep -q "$marker" "$tmp"; then
    rm -f "$tmp"
    echo "WARNING: the course licence was not embedded in this script."
    echo "Tell the TA - they will paste it into the script."
    magpie_report "setup: WARNING gamslice not embedded"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# GAMS reads gamslice.txt from that folder, so no env var is needed.
magpie_install_licence() {
  local dir target tmp
  dir=$(magpie_licence_dir)
  target="$dir/gamslice.txt"
  if [ -f "$target" ]; then
    echo "Course licence: already in place."
    return 0
  fi
  magpie_licence_available || return 1
  mkdir -p "$dir"
  chmod 700 "$dir"
  tmp=$(mktemp)
  magpie_licence_text > "$tmp"
  mv "$tmp" "$target"
  chmod 600 "$target"
  echo "Course licence written to $target"
}

magpie_find_gams() {
  if command -v gams >/dev/null 2>&1; then
    command -v gams
    return 0
  fi
  if [ -x "/Library/Frameworks/GAMS.framework/Resources/gams" ]; then
    echo "/Library/Frameworks/GAMS.framework/Resources/gams"
    return 0
  fi
  return 1
}

magpie_sha256() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

magpie_install_gams() {
  if magpie_find_gams >/dev/null; then
    echo "GAMS: already installed."
    return 0
  fi
  local url sha pkg
  if [ "$(uname -m)" = "arm64" ]; then
    url="$GAMS_URL_ARM64"
    sha="$GAMS_SHA256_ARM64"
  else
    url="$GAMS_URL_X86"
    sha="$GAMS_SHA256_X86"
  fi
  pkg="$HOME/magpie-downloads/GAMS$GAMS_VERSION.pkg"
  mkdir -p "$HOME/magpie-downloads"
  if [ -f "$pkg" ] && [ "$(magpie_sha256 "$pkg")" != "$sha" ]; then
    rm -f "$pkg"
  fi
  if [ ! -f "$pkg" ]; then
    echo "Downloading GAMS $GAMS_VERSION (~500 MB, a few minutes)..."
    echo "If this fails: rerun the same command, it downloads again."
    if ! curl -fL --retry 3 -C - --progress-bar -o "$pkg" "$url"; then
      echo "Download failed. Rerun this file."
      magpie_report "setup: FAIL gams download"
      return 1
    fi
    if [ "$(magpie_sha256 "$pkg")" != "$sha" ]; then
      rm -f "$pkg"
      echo "Download corrupt (checksum mismatch). Rerun this file."
      magpie_report "setup: FAIL gams download corrupt"
      return 1
    fi
  fi
  echo "Installing GAMS package - macOS will ask for your password..."
  magpie_sudo_keep
  if ! sudo installer -pkg "$pkg" -target /; then
    echo "Package install failed. Rerun this file, then tell the TA."
    magpie_report "setup: FAIL gams pkg install"
    return 1
  fi
  rm -f "$pkg"
  echo "GAMS $GAMS_VERSION installed."
  magpie_report "setup: gams $GAMS_VERSION installed"
}

magpie_register_gams() {
  local rc="$HOME/.zshrc"
  if ! command -v gams >/dev/null 2>&1 \
    && [ -d "/Library/Frameworks/GAMS.framework/Resources" ] \
    && magpie_rc_add_path "$rc" "/Library/Frameworks/GAMS.framework/Resources"; then
    echo "Added GAMS to PATH in $rc"
  fi
}

magpie_register_hu_key() {
  local rc="$HOME/.zshrc"
  touch "$rc"
  if ! grep -q HU_API_KEY "$rc"; then
    printf 'export HU_API_KEY="required-but-not-used"\n' >> "$rc"
    echo "Set HU_API_KEY in $rc (also active in this run)."
  fi
  export HU_API_KEY="required-but-not-used"
}

magpie_ensure_base_profile() {
  if ! command -v nono >/dev/null 2>&1; then
    echo "NOTE: nono not found - skipping the sandboxed final check."
    magpie_report "setup: NOTE nono missing, no sandbox check"
    return 1
  fi
  if nono profile list 2>/dev/null | grep -qE '^[[:space:]]+opencode([[:space:]]|$)'; then
    return 0
  fi
  echo "Installing the base nono profile 'opencode'..."
  if ! nono pull nolabs-ai/opencode; then
    echo "Could not install the 'opencode' profile. Tell the TA."
    magpie_report "setup: FAIL base opencode profile pull"
    return 1
  fi
}

magpie_build_nono_profile() {
  local dir="$HOME/.config/nono/profiles" f tmp
  f="$dir/magpie-profile.json"
  mkdir -p "$dir"
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
{
  "meta": {
    "name": "magpie-profile",
    "description": "MAgPIE course: opencode + GAMS + R + TinyTeX"
  },
  "extends": ["opencode"],
  "filesystem": {
    "read": [
      "/Library/Frameworks/GAMS.framework",
      "/Library/Frameworks/R.framework",
      "/usr/local/gfortran",
      "$HOME/.TinyTeX",
      "$(magpie_licence_dir)"
    ]
  }
}
EOF
  if ! nono profile validate "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "Generated nono profile failed validation - tell the TA."
    magpie_report "setup: FAIL nono profile invalid"
    return 1
  fi
  if [ -f "$f" ]; then
    if cmp -s "$tmp" "$f"; then
      echo "nono profile magpie-profile: already in place."
    else
      echo "nono profile $f was changed - keeping it (delete it to regenerate)."
    fi
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$f"
  echo "Created nono profile: $f"
}

magpie_texbin() {
  local d texbin
  texbin=$(dirname "$(command -v tex 2>/dev/null || echo /nonexistent)")
  if [ -x "$texbin/tex" ]; then
    echo "$texbin"
    return 0
  fi
  for d in "$HOME"/.TinyTeX/bin/*/; do
    if [ -x "${d}tex" ]; then
      printf '%s\n' "${d%/}"
      return 0
    fi
  done
}

magpie_register_tex() {
  local texbin rc="$HOME/.zshrc"
  texbin=$(magpie_texbin)
  if [ -z "$texbin" ]; then
    return 0
  fi
  if magpie_rc_add_path "$rc" "$texbin"; then
    echo "Added TinyTeX to PATH in $rc"
  fi
}

magpie_sandbox_check() {
  local texbin
  texbin=$(magpie_texbin)
  echo "Final check inside the course sandbox (nono, profile magpie-profile)..."
  nono run --profile magpie-profile -- env MAGPIE_CHECK_ONLY=1 \
    PATH="${texbin:+$texbin:}$PATH" \
    bash "$0" --check-only \
    || echo "Sandboxed check failed - show the FAIL line to the TA."
}

magpie_show_help() {
  local sys f="$HOME/magpie-help.txt"
  sys="macOS $(sw_vers -productVersion 2>/dev/null)"
  {
    printf 'I am a beginner setting up MAgPIE. Fix the FAIL lines below.\n'
    printf 'Tell me exactly what to type in the terminal, one command at a time.\n'
    printf 'System: %s | %s | code name: %s\n' "$sys" "$(uname -m)" "$MAGPIE_HANDLE"
    printf '%s\n' "$1"
    printf -- '--- last setup output ---\n'
    tail -n 25 "$HOME/magpie-setup-log.txt" 2>/dev/null
  } > "$f"
  echo
  echo "===== NEED HELP? Select EVERYTHING between the ## lines below and"
  echo "paste it into opencode or any AI chat - or open the file $f ====="
  echo "##"
  cat "$f"
  echo "##"
}

git_new_enough() {
  local v major rest minor
  v=$(git --version | awk '{print $3}')
  major=${v%%.*}
  rest=${v#*.}
  minor=${rest%%.*}
  echo "git $v"
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 23 ]; }
}

magpie_run_checks() {
  local results=() gbin gout r report_block git_msg
  pass() {
    results+=("PASS $1")
  }
  fail() {
    results+=("FAIL $1")
  }

  if gbin=$(magpie_find_gams); then
    gout=$( cd "$(mktemp -d)" && "$gbin" 2>&1 || true )
    if grep -qiE "license is valid|licensee" <<< "$gout"; then
      pass "gams (license found - ask TA to confirm CONOPT once)"
    else
      fail "gams found but its licence file is missing - rerun this file"
    fi
  else
    fail "gams not installed - rerun this file"
  fi

  if command -v git >/dev/null 2>&1; then
    if git_msg=$(git_new_enough); then
      pass "$git_msg"
    else
      fail "$git_msg older than 2.23 - tell the course team"
    fi
  else
    fail "git not found - rerun this file"
  fi

  if command -v Rscript >/dev/null 2>&1; then
    if Rscript -e 'quit(status = if (getRversion() >= "4.3") 0 else 1)' 2>/dev/null; then
      pass "R $(Rscript -e 'cat(as.character(getRversion()))' 2>/dev/null)"
    else
      fail "R older than 4.3 - tell the course team"
    fi
  else
    fail "Rscript not found - install the R .pkg, then rerun this file"
  fi

  if command -v pandoc >/dev/null 2>&1; then
    pass "pandoc $(pandoc --version | head -n1 | awk '{print $2}')"
  else
    fail "pandoc not found - rerun this file"
  fi

  if command -v tex >/dev/null 2>&1; then
    pass "tex (TinyTeX)"
  else
    fail "tex not found - rerun this file"
  fi

  if [ -f renv.lock ]; then
    if Rscript -e 'suppressMessages(library(lucode2)); suppressMessages(library(gms))' >/dev/null 2>&1; then
      pass "renv R library (lucode2, gms load)"
    else
      fail "renv R library incomplete - in ~/magpie run: Rscript -e 'renv::restore()'"
    fi
  else
    results+=("SKIP renv check (rerun this file inside ~/magpie to include it)")
  fi

  echo
  echo "===== your result - it went to the course feed ====="
  echo "system: $(uname -s) $(uname -m) | code name: $MAGPIE_HANDLE"
  for r in "${results[@]}"; do
    echo "$r"
  done
  echo "===== end of copy block ====="

  report_block="check result"
  if [ "${MAGPIE_CHECK_ONLY:-0}" = "1" ]; then
    report_block="sandbox check result"
  fi
  for r in "${results[@]}"; do
    report_block="$report_block
$r"
  done
  magpie_report "$report_block"

  local failed=0
  for r in "${results[@]}"; do
    if [[ "$r" == FAIL* ]]; then
      failed=1
    fi
  done
  if [ "$failed" -eq 1 ]; then
    magpie_show_help "$report_block"
    return 1
  fi
  return 0
}

magpie_print_next_steps() {
  echo
  echo "NEXT STEPS (same on the course page):"
  echo "  cd ~"
  echo "  git clone https://github.com/magpiemodel/magpie.git"
  echo "  cd magpie"
  echo "  Rscript -e 'renv::restore()'        # type y if asked, ~1-2 GB"
  echo "  rerun this setup file once more inside ~/magpie (final check)"
  echo "  caffeinate -is Rscript start.R      # choose 1, then 1 - runs overnight"
  echo "Laptop: plugged into power, lid open / sleep off, overnight."
}

magpie_main() {
  if [ "${1:-}" = "--check-only" ]; then
    magpie_greet
    magpie_run_checks
    exit $?
  fi

  exec > >(tee "$HOME/magpie-setup-log.txt") 2>&1
  if [ "$(uname)" != "Darwin" ]; then
    echo "This file is for macOS. In the Ubuntu (WSL) terminal use setup-ubuntu.sh."
    exit 1
  fi

  magpie_greet
  magpie_report "setup: start"

  magpie_check_disk
  magpie_licence_available || true

  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Installing the Xcode Command Line Tools."
    echo "A window opens. Click Install, then WAIT until it finishes (up to 20 min)."
    xcode-select --install
    echo "When the window says done: rerun this file."
    magpie_report "setup: opened Xcode CLT installer, waiting"
    exit 0
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is missing. Paste this one line, press Return,"
    echo "type your password when asked, press Return again:"
    echo
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo
    echo "When it finishes: rerun this file."
    magpie_report "setup: Homebrew missing, printed install line"
    exit 0
  fi

  magpie_install_agents
  magpie_fix_bin_path
  magpie_opencode_config
  magpie_report "setup: agents + opencode config done"

  magpie_register_hu_key

  echo "Installing brew tools (this can take a while)..."
  brew install git pandoc cmake pkg-config libgit2 libxml2 gdal fribidi \
    harfbuzz libpng libtiff abseil \
    || magpie_report "setup: FAIL brew install"

  local missing=0
  if ! Rscript -e 'quit(status = if (getRversion() >= "4.3") 0 else 1)' 2>/dev/null; then
    echo "R is missing or older than 4.3."
    echo "Double-click the .pkg for $(uname -m) at https://cran.r-project.org/bin/macosx/"
    missing=1
    magpie_report "setup: missing R .pkg"
  fi
  if ! command -v gfortran >/dev/null 2>&1 && [ ! -x /usr/local/gfortran/bin/gfortran ]; then
    echo "gfortran is missing: double-click the .pkg at https://cran.r-project.org/bin/macosx/tools/"
    missing=1
    magpie_report "setup: missing gfortran .pkg"
  fi
  if [ "$missing" -eq 1 ]; then
    echo "Install those two (double-click, password), then RERUN this file."
    exit 0
  fi

  magpie_install_gams || true
  magpie_install_licence || true
  magpie_register_gams

  if command -v Rscript >/dev/null 2>&1 && [ ! -d "$HOME/.TinyTeX" ]; then
    echo "Installing TinyTeX (a few minutes)..."
    if ! Rscript -e 'install.packages("tinytex", repos = "https://cloud.r-project.org")' \
      || ! Rscript -e 'tinytex::install_tinytex()'; then
      magpie_report "setup: FAIL TinyTeX install"
    fi
  fi
  magpie_register_tex

  magpie_run_checks || echo "Some checks FAILED. Rerun once; then copy the ## help block into opencode; then 2 neighbors, TA."

  if magpie_ensure_base_profile && magpie_build_nono_profile; then
    magpie_sandbox_check
  fi

  magpie_print_next_steps
  magpie_report "setup: run finished"
}

if [ -z "${MAGPIE_SOURCED:-}" ]; then
  magpie_main ${1+"$@"}
fi
