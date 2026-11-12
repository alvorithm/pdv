# pdv

pdv is the Penpot development-environment manager: it owns the instance bring-up and the window set, and every verb it does not own falls through to Penpot's `manage.sh` unchanged.

## Layout

- `pdv`: the dispatcher, the flag parsing, and the verb table.
- `lib/pdv-core.sh`: checkout resolution, the workspace briefing, the waits, the failure report, the ACL grant, and the post-start tune.
- `lib/pdv-services.sh`: the window plan, the heap cap, and the watcher commands.
- `share/`: data files the tune installs into an instance.
- `test/parity.sh`: the regression net.
- `docs/manual-pdv.md`: the manual that `README.md` links to.

## The contract

[CONTRIBUTING.md](CONTRIBUTING.md) carries the checks every change passes and the upstream plan for every workaround. A new workaround adds its section there in the same commit.

## Commits

Commit bodies wrap at 72 columns. Commits sign with the SSH key held by the agent: never pass `--no-gpg-sign` and never amend a pushed commit.
