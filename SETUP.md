# MAgPIE course setup - student guide

Your setup progress is uploaded live to the course team - nothing to paste
into any website. Note your code name (below) and that is all.

**ONE file does everything.** You download it, run it, done. It installs the
tools, GAMS, the course licence, opencode and nono (the AI helper and its
sandbox) if they are missing, the opencode settings, and then checks
everything.

**How to open the terminal:**
- Mac: press Cmd+Space, type `Terminal`, press Return.
- Windows: press the Windows key, type `Ubuntu`, press Return.

**How to paste:** Mac: Cmd+V. Windows/Ubuntu: right-click or Ctrl+Shift+V.

**Your code name:** the first run shows a name like `Zebra347`.
NOTE IT DOWN (paper or phone)! Your progress is uploaded under this name so
the course team can help you. They will call it out - if you hear your name,
raise your hand. It is saved on your laptop, you always get the same one.

**Golden rules:**
- If anything fails: RERUN the same command. It repeats only what is missing.
- The password is your login password, typed blind - nothing shows. Normal.
- Long waits with no output are normal. Do not close the terminal.
- You need about 15 GB free disk - the setup file checks this first and
  tells you what to clean. On WSL, clean up in WINDOWS (C: drive).
- Weak room Wi-Fi? Use your phone hotspot for the download steps (~3 GB).
- Stuck? On any FAIL the file prints a help block (between `##` lines):
  copy it into opencode or any AI chat and follow its advice. Then: two
  neighbors -> raise your hand.

---

## Mac

1. In your browser open Moodle, go to the course, and download
   `setup-macos.sh`.
2. In the terminal run:

   ```
   bash ~/Downloads/setup-macos.sh
   ```

3. The file stops when YOU must do something - always then:
   - Command Line Tools window opened -> click Install, wait until it is done.
   - A Homebrew line is printed -> paste that line, password, Return twice.
   - It says R or gfortran .pkg missing -> open the printed web page,
     download, double-click, password. Pick **arm64** if you have an
     M1-M4 chip, **x86_64** for Intel.
   Then RERUN the same command. Repeat until it runs to the end.
4. It downloads GAMS (~500 MB) and installs it - it asks your password.
   Big downloads may break: just rerun, it downloads the file again.
5. Once ever installed anaconda/miniconda? Run `conda deactivate` before
   starting MAgPIE. (No idea what that means? You have no conda. Skip.)

## Ubuntu (WSL)

1. Download `setup-ubuntu.sh` in your **Windows** browser (Moodle needs your
   login, so do NOT download inside Ubuntu). Then copy it into Linux - in
   the Ubuntu terminal run (replace YOURNAME with your Windows username):

   ```
   cp /mnt/c/Users/YOURNAME/Downloads/setup-ubuntu.sh ~/
   ```

   Tip: in the Ubuntu terminal type `cd /mnt/c/Users/` then press Tab to
   find your username folder.

2. Run it:

   ```
   bash ~/setup-ubuntu.sh
   ```

   It downloads GAMS (~670 MB) - if a download breaks, rerun, it downloads
   the file again.

## At the end of every run

The file prints a block between `=====` lines with PASS/FAIL lines - the
same block goes to the course feed under your code name automatically:
- If any FAIL: rerun the file once. Still failing? The file now also prints
  a help block between `##` lines - copy ALL of it into opencode (or any AI
  chat) and do exactly what it says. It is saved in `~/magpie-help.txt` too.
- When all PASS (except the renv SKIP line): you are done with this part!

On a good run the file finally starts a sandbox (nono, profile
`magpie-profile`) and repeats the check inside it. That sandboxed check is
the one the course team confirms - expect the same answers. If only the
sandboxed one fails, show its FAIL line to the TA.

## Download MAgPIE and its R packages (longest step - be patient)

Store it in your Home folder only.

```
cd ~
git clone https://github.com/magpiemodel/magpie.git
cd magpie
Rscript -e 'renv::restore()'
```

Type `y` + Return if asked. This is ~1-2 GB. When it ends without red text,
run the setup file ONCE MORE while you are inside `~/magpie` (the last check
needs that folder). All lines PASS - no FAIL, no SKIP? Done - the TA will
confirm your code name on the course feed.

## Start the first model run (finishes overnight)

```
cd ~/magpie
caffeinate -is Rscript start.R     # Mac
Rscript start.R                    # Ubuntu
```

1. For the run type `1`, Return (default run).
2. For how to run type `1` (direct execution), Return.
3. The first run downloads some GB of input data and computes for hours.
   This is homework - it must not finish today.
4. Overnight: laptop plugged into power, lid open / sleep disabled.

---

## opencode help card

Paste this into opencode when stuck (fill your name/system):

```
I am a student setting up MAgPIE on macOS/Ubuntu-WSL.
My setup file is setup-macos.sh (or setup-ubuntu.sh) in my home or
Downloads folder. Run it again, read the FAIL lines, diagnose the problem,
and fix it. Show me each command before running it.
If a command needs sudo, print it for me to run myself.
Do not change the GAMS licence or the teacher section of the file.
When unsure, tell me to ask the TA instead of guessing.
```
