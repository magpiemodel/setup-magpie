# moodle message

Hey all,
I've created a new script called "magpie-opencode.sh". It installs everything you need for now (git, curl, opencode, HU LLM service, nono, nono profile for opencode), it will also download magpie and start a sandboxed opencode in the magpie folder, so you only need one single command for both setup and running opencode.

Instructions:
Download magpie-opencode.sh from moodle using your regular web browser.
On mac open a terminal (press Cmd+Space, type `Terminal`, press Enter) and run:
`bash ~/Downloads/magpie-opencode.sh`

On Windows open Ubuntu/WSL (press the Windows key, type `Ubuntu`, press Enter; do NOT open powershell) and run:
`bash /mnt/c/Users/*/Downloads/magpie-opencode.sh`

You should see the opencode prompt, with llm3 (=HU LLM service) preselected.
IMPORTANT: The HU LLM service will ONLY work if you are connected to HU local wifi or HU VPN. You can select a different model by running `/models` in opencode, the opencode free models work without VPN, I know GLM 5.3 is decent. We encourage you to try different models to figure out which ones work well for you. For the free models your data is likely stored/used for training, so don't enter/let the LLM read sensitive data (magpie is open source anyway, and nono blocks access to your computer outside of the magpie folder).
