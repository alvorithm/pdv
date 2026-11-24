---
name: pdv
description: Work in a Penpot development instance that pdv runs. Covers finding or giving a worktree its own instance, pointing an instance at another worktree, recovering a container that exits at start, running a command inside the container, running backend tests (a focused run in the persistent test JVM or a cold CI-style suite), evaluating Clojure, restarting the backend, connecting an editor's REPL and language server, logging in for a UI check, and running the Playwright suite. Use when a task needs a running Penpot or its backend JVM and `pdv help` does not say how, and before removing or recreating a devenv container.
---

# Working in a Penpot instance that pdv runs

`pdv help` lists every verb and flag, and `pdv testjvm help` and `pdv eval --help` list the test tools' subcommands and exit codes. This skill holds only the sequences those do not spell out. The model behind them is the pdv manual, `docs/manual-pdv.md` in the pdv checkout.

An instance is a slot `wsN`, and its container is `penpot-devenv-wsN-main`. Slot N binds the symlink `$PENPOT_WORKSPACES_DIR/wsN`, which defaults to `~/.local/share/penpot-devenv/workspaces/wsN`, and ws0 binds the checkout pdv runs from. Each worktree has its own database and bucket, so pointing a slot at another worktree also switches the data.

## Find the instance before starting one

`pdv status` lists every instance with its state, its ports, the tree it serves, and warnings about what has drifted. Use the instance whose tree is your worktree. Otherwise take a slot that no instance uses. `pdv status` prints a broken instance's state and log tail in place, so never attach to diagnose one.

`testjvm`, `eval`, `repl`, `lsp`, and `jobs` pick the instance that serves the worktree you run them from, and print it on their first line. Run them from your worktree and pass no `--ws`. Exit 3 with a list of instances means no running instance serves that worktree: start one, or pass `--ws N` when another instance is the one you mean.

## Give a worktree its own instance

```sh
ln -sn ~/Worktrees/penpot-<name> ~/.local/share/penpot-devenv/workspaces/wsN
pdv run --ws N --services backend,frontend
```

`~/Worktrees/penpot-<name>` stands for wherever the worktree lives.

## Point a slot at another worktree

```sh
pdv stop --ws N
ln -sfn ~/Worktrees/penpot-<other> ~/.local/share/penpot-devenv/workspaces/wsN
pdv run --ws N --recreate --services backend,frontend
```

`pdv stop` removes the container, and with it anything running inside, such as the test JVM. `--recreate` removes a container that survived the stop and keeps every volume, so the new container binds the new tree.

Never remove a devenv container or its stack by hand, with `docker rm`, `docker compose down`, or `manage.sh drop-devenv`. The pdv verbs keep the volumes and say what they remove. `drop-devenv` also removes the image.

## Recover a container that exits at start

When the main container is `Exited (1)` and its log ends with `host not found in upstream`, the container is attached to a Docker network that no longer exists. Run `pdv run --ws N --recreate`.

## Run backend tests

A focused run goes to the persistent test JVM, which keeps the backend loaded and reloads only what changed:

```sh
pdv testjvm status                          # is it up, and is it current
pdv testjvm start                           # once per container, when status says it is not running
pdv testjvm run backend-tests.<ns>          # a namespace, or ns/test-name for one var
```

Read the exit status, not only the output. 0 passed, 1 a test failed or none matched, 2 the reload failed (the line names the file), 3 the JVM is down, 4 the deadline passed, 5 the JVM needs `pdv testjvm restart`, 6 the storage is not writable (`pdv testjvm repair`). After a `deps.edn` change, or an edit under `backend/dev`, the run answers 5. Restart the JVM then, and never restart or stop a test JVM another session started while its run holds it.

The whole suite, or a run that must match CI exactly, is a cold run in a fresh JVM under the same lock:

```sh
pdv testjvm cold                            # the whole backend suite
pdv testjvm cold --focus backend-tests.<ns>
```

Runs on one instance wait for each other, because they share its test database. A whole-suite run takes many minutes, so give it a long timeout or run it in the background.

## Evaluate Clojure

`pdv eval` checks a function or an assumption in the test JVM, after the same reload a test run does. Pass code on stdin to avoid shell quoting, and write fully qualified names:

```sh
pdv eval - <<'EOF'
(require 'app.common.data)
(app.common.data/index-by :id [{:id 1}])
EOF
```

`--target backend` evaluates in the running backend, with `app.system/system` and the instance's database. Nothing is reloaded there, so hot-load an edited file with `pdv eval --target backend --file <path>`. Prefer the test JVM for anything that writes data.

## Restart the backend

A change a reload cannot reach (a config value read at start, a new dependency, a component of `app.system`) needs a backend process restart:

```sh
pdv restart --services backend
```

Run it from the worktree's instance, adding `--ws N` for any slot other than ws0, because `restart` defaults to ws0 like `start` and `stop`. The verb stops the backend window's process, starts it again with the worktree's database and heap, and returns once the new process answers on its nREPL. Never call `(app.main/restart)`: the in-JVM refresh can leave graph sync, websocket notifications, and realtime collaboration dead until a process restart.

## Connect an editor

- **REPL.** `pdv repl` starts cider-nrepl inside the backend and bridges it to host port `6064 + 10000 × N`, writing that port to the worktree's `.nrepl-port`. It runs in the foreground, needs `python3` on the host, and replaces an older bridge on the same port. Connect the editor's nREPL client to `127.0.0.1` and that port. A backend restart takes the cider server down, so run `pdv repl` again afterwards.
- **Language server.** Configure `pdv lsp` as the clojure-lsp binary. An editor started in the worktree needs no arguments, and an editor that serves several worktrees passes `--ws N`. The server runs inside the instance with the full classpath, and paths come back as host paths.

## Run a command inside the container

```sh
docker exec -u penpot -w /home/penpot/penpot penpot-devenv-wsN-main bash -lc '<command>'
```

Always pass `-u penpot`. A build or a test run as the container's root leaves directories the `penpot` user cannot write, and later test runs fail on them until `pdv testjvm repair`.

## Log in for a UI check

A UI check logs in as the seeded owner, `zeus@penpot.app` with password `123123`, and never registers a new user. An agent that calls the RPC API uses the account and token in the worktree's `.pdv-agent.json`. Never print that token or commit the file. Work that should outlive the worktree goes back to the fixture repository with `pdv bundle save` before the worktree is removed.

## Run the Playwright suite

From `frontend/` inside the container, run `CI=true pnpm exec playwright test --project default --workers=4`. Four workers are faster than the one the configuration defaults to. `pnpm run test:e2e` sets no worker count, so add `--workers=4` to it without a `--` separator.

## Check whether background work arrived

`pdv jobs` lists the instance's newest job-table rows. A save that seems to vanish leaves a `process-webhook-event` row that reaches `completed` seconds later, and a failed job carries its error there.
