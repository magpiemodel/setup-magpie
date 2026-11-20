# magpie setup scripts

Created to setup opencode, nono, and magpie (incl. all dependencies) on student laptops (Windows -> WSL Ubuntu, macOS).

## magpie-opencode.sh

Starts a
- nono-sandboxed
- opencode session
- connected to Humboldt University LLM service (requires VPN/HU-wifi!)
- in magpie folder.

If any of the tools required for that are missing they are installed first, magpie is cloned if needed.


### moodle message for students

Hey all,
magpie-opencode.sh installs everything you need for now (git, curl, opencode, HU LLM service, nono, nono profile for opencode), it will also download magpie and start a sandboxed opencode in the magpie folder, so you only need one single command for both setup and running opencode.

Instructions:
Download magpie-opencode.sh from moodle (attached to this discussion topic) using your regular web browser.
On mac open a terminal and run:
`bash ~/Downloads/magpie-opencode.sh`

On Windows open Ubuntu/WSL (NOT powershell) and run:
`bash /mnt/c/Users/*/Downloads/magpie-opencode.sh`

You should see the opencode prompt, with llm3 (=HU LLM service) preselected.
IMPORTANT: The HU LLM service will ONLY work if you are connected to HU local wifi or HU VPN. You can select a different model by running `/models` in opencode, the opencode free models work without VPN, I know GLM 5.3 is decent. We encourage you to try different models to figure out which ones work well for you. For the free models your data is likely stored/used for training, so don't enter/let the LLM read sensitive data (magpie is open source anyway, and nono blocks access to your computer outside of the magpie folder).


## setup-magpie.sh

Will install everything that magpie-opencode.sh would install, plus
- magpie system dependencies (R, gdal, ...)
- gams incl. license (license must be pasted into setup-magpie.sh first)
- magpie R package dependencies (terra, magpie4, ...)
- nono profile to allow everything necessary to install R packages and run magpie
- run default magpie run incl. post-processing inside nono sandbox
- report issues if any

### moodle message for students

Hey all, setup-magpie.sh installs everything you need to actually run magpie (R, gams incl. license, and more). The gams license is part of the script, and it is only for the course (gams is super expensive normally!), so don't share the script.
If the script fails the error messages are anonymized and uploaded to PIK cloud, so we can adapt the script accordingly. You can just let the script run in the background, you don't need to fix issues yourself (for now).

Instructions: Download setup-magpie.sh from moodle using your regular web browser.

On mac open a terminal (press Cmd+Space, type Terminal, press Enter) and run:
`bash ~/Downloads/setup-magpie.sh`

On Windows open Ubuntu/WSL (press the Windows key, type Ubuntu, press Enter; do NOT open powershell) and run:
`bash /mnt/c/Users/*/Downloads/setup-magpie.sh`
