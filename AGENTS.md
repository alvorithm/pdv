# pdv

pdv is the Penpot development-environment manager: it owns the instance bring-up and the window set, and every verb it does not own falls through to Penpot's `manage.sh` unchanged.

## Layout

- `pdv`: the dispatcher, the flag parsing, and the verb table.
- `lib/pdv-core.sh`: checkout resolution, the workspace briefing, the waits, the failure report, the ACL grant, and the post-start tune.
- `lib/pdv-services.sh`: the window plan, the heap cap, and the watcher commands.
- `test/parity.sh`: the regression net.
- `docs/manual-pdv.md`: the manual that `README.md` links to.

## The contract

- A behaviour change lands with the parity harness covering it. `test/parity.sh` runs offline by default, and `--live --fast` adds the comparison against `./manage.sh run-devenv` on a running instance.
- pdv never restates the compose environment that `manage.sh` computes. The fall-through is the drift guard.
- pdv depends only on the checkout's `manage.sh`, the files tracked in the Penpot repository, and the devenv image. It calls no untracked helper from the checkout, so it runs on a stock clone.
- The README and the manual carry the user-facing surface. A flag that changes behaviour changes them in the same commit.
- bash 4 or newer on the host, and every script passes `bash -n`.

## Commits

Commit bodies wrap at 72 columns. Commits sign with the SSH key held by the agent: never pass `--no-gpg-sign` and never amend a pushed commit.
