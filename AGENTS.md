# pdv

pdv is the Penpot development-environment manager: it owns the instance bring-up and the window set, and every verb it does not own falls through to Penpot's `manage.sh` unchanged.

## Layout

- `pdv`: the dispatcher, the flag parsing, and the verb table.
- `lib/pdv-core.sh`: checkout resolution, the workspace briefing, the waits, the failure report, the status checks of what a container serves, the ACL grant, and the post-start tune.
- `lib/pdv-services.sh`: the window plan, the heap cap, the watcher commands, and the pane liveness that status reports.
- `lib/pdv-seed.sh`: the per-worktree database and bucket, the seed profile staging, the download cache, the orphan sweep, and the seed and bundle verbs.
- `lib/pdv-tools.sh`: the development tools on a running instance (`testjvm`, `eval`, `repl`, `lsp`, `jobs`) and the selection of the instance that serves the caller's worktree.
- `lib/repl-bridge.py`: the host side of the editor REPL bridge, which `pdv repl` runs.
- `share/`: data files the tune installs into an instance, the built-in default seed profile, the seed driver (`pdv-seed.bb`, run with the container's Babashka) and engine (`seed.clj`, loaded into the backend JVM), and the code `docker exec` carries into the container for the tools: the test JVM harness (`testjvm.clj`, `testjvm-log4j2.xml`), the nREPL client (`nrepl-client.py`), and the LSP path translator (`lsp-bridge.py`).
- `skills/pdv/SKILL.md`: the agent skill that teaches a harness the recipes `pdv help` does not spell out.
- `test/parity.sh`: the regression net.
- `docs/manual-pdv.md`: the manual that `README.md` links to.

## The contract

[CONTRIBUTING.md](CONTRIBUTING.md) carries the checks every change passes and the upstream plan for every workaround. A new workaround adds its section there in the same commit.

## Commits

Commit bodies wrap at 72 columns. Commits sign with the SSH key held by the agent: never pass `--no-gpg-sign` and never amend a pushed commit.
