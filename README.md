# pdv

Penpot's `manage.sh run-devenv` starts four windows at once: the frontend watcher, Storybook, the exporter, and the backend, plus the MCP and Serena windows in agentic mode. On a laptop, four windows mean more heap and more compiling than the work needs. pdv starts the windows you name, caps the heap of the three JVMs those windows start, and keeps the compile caches between restarts.

pdv owns the instance bring-up and the window set, the per-worktree database and its seeding, the development tools on a running instance (a persistent test JVM, Clojure evaluation, the editor REPL and language server, and the job table), plus two hygiene verbs that `run` also applies on its own: `acl` and `tune`. Any other `manage.sh` verb runs unchanged, so `pdv pull-devenv` is `manage.sh pull-devenv` and an upstream flag works here on the day it lands. pdv depends on nothing but the checkout's `manage.sh`, the files the Penpot devenv image ships, and `curl` on the host, plus `python3` on the host for `pdv repl`.

## Requirements

- Docker, rootless or rootful, with the Penpot devenv image (`./manage.sh pull-devenv`).
- A Penpot checkout that carries `manage.sh`.
- bash 4 or newer, coreutils, and `curl` on the host.
- `python3` on the host for `pdv repl` alone, which runs the host side of the editor REPL bridge.
- `setfacl` (the `acl` package) on a rootless Docker host.
- A checkout of the fixture repository (`~/Code/penpot-fixtures`, or `PDV_FIXTURES`) for named seed profiles. Without it, a database gets pdv's built-in default users and no fixtures.

## Install

Copy or clone this repository to `~/Code/pdv`, then link the command onto your PATH:

```sh
ln -s ~/Code/pdv/pdv ~/.local/bin/pdv
```

An agent setting pdv up for someone else follows [docs/setup-for-agents.md](docs/setup-for-agents.md).

pdv finds the checkout in this order: `--repo PATH`, `PENPOT_REPO`, the git worktree you run it from, then `~/Code/penpot`. Name one explicitly when the checkout you want is not the worktree you call pdv from:

```sh
pdv run --repo ~/work/penpot --services frontend,backend
```

## Start an instance

```sh
pdv run                                              # every window start-tmux.sh creates
pdv run --services frontend,backend                  # the usual development preset
pdv run --only-backend                               # backend work, no watcher compile
pdv run --agentic --services frontend,backend,mcp    # with the MCP server
```

`pdv run --ws 2` brings up the ws2 instance instead of ws0. pdv checks `--ws` against the ceiling in `manage.sh`, so an index that would overflow the port range is refused with the same ceiling and reason `manage.sh` gives.

An instance that is already running is tuned, and any selected window that is missing or stopped is started in place. Pass `--recreate` to replace its container.

## Services

Each service is one tmux window. `--services` takes a positive list, and the windows appear in this order.

| service     | window               | what runs                                                                       |
| ----------- | -------------------- | ------------------------------------------------------------------------------- |
| `frontend`  | `frontend watch`     | shadow-cljs watch over `main` and `worker`, with the asset and library watchers |
| `storybook` | `frontend storybook` | the Storybook dev server                                                        |
| `exporter`  | `exporter`           | the exporter watcher and its service pane                                       |
| `backend`   | `backend`            | `./scripts/start-dev`                                                           |
| `mcp`       | `mcp`                | the MCP server                                                                  |
| `serena`    | `serena`             | the Serena server, in agentic mode                                              |

`storybook` also puts the `storybook` compile target back into the frontend watcher, so pdv refuses a selection that names `storybook` without `frontend`. `--watchers` is the `frontend,storybook,exporter` shorthand.

## A database and a bucket per worktree

Every instance used to share the `penpot` database and object store, so two worktrees on branches with different migrations ran against one schema. pdv now names a database and a bucket after the worktree it binds, creates them before the backend starts, and seeds them from a profile in the fixture repository.

```sh
pdv run --seed branching        # pdvwt_<slug>, seeded from profiles/branching.yaml
pdv run --db penpot             # the shared legacy database, never seeded
pdv seed status                 # what the database holds
pdv bundle save bundles/branching/review-pair.penpot --project review-pair
```

`pdvwt_<slug>` and `pdvwt-<slug>` follow the worktree directory, so `penpot-iop-vc-preview` becomes the database `pdvwt_penpot_iop_vc_preview` and the bucket `pdvwt-penpot-iop-vc-preview`. An unchanged profile imports nothing, and a changed one rebuilds the database before the backend starts. `pdv seed` rebuilds now. Without a profile the database still gets the built-in one: `zeus@penpot.app` owns the team "Work on this worktree", `aeolus@penpot.app` is the agent, and nothing is imported. Every seeded password is `123123`.

The choice is remembered per worktree in its git directory, and `.pdv-agent.json` holds the agent account's URL, email, and token after a seed. The naming rules, the profile schema, the lifecycle, the orphan sweep, and `--db penpot` are in [the manual](docs/manual-pdv.md#each-worktree-gets-its-own-database-and-bucket).

## Three flags carry the policy

**The heap cap.** `run` and every service window start carry `-Xmx768m -Xms50m` in `_JAVA_OPTIONS`, with `JAVA_OPTS` set to the same value where a script reads it. The frontend, exporter, and backend JVMs read the cap. `_JAVA_OPTIONS` is the channel that survives, because the image's `bashrc` and the backend's `scripts/_env` both re-export `JAVA_OPTS` without `-Xmx` ([why the channel matters](docs/manual-pdv.md#the-heap-cap-travels-in-_java_options-because-two-scripts-reset-java_opts)).

```sh
pdv run --java-opts "-Xmx1500m -Xms50m"   # more room for a large backend
pdv run --java-opts ""                    # uncapped, the JVM default
DEVENV_JAVA_OPTS="-Xmx512m" pdv run       # the same value from the environment
```

**The caches.** A start reuses both compile caches, and only the first start on a tree builds the Rust/WASM renderer. Upstream's watcher clears the caches and rebuilds the renderer on every start, which costs minutes ([what the clears cost](docs/manual-pdv.md#a-watcher-restart-keeps-the-caches-and---clean-answers-a-toolchain-change)).

```sh
pdv run --clean   # the exact upstream behaviour: clear both caches, rebuild wasm
```

Reach for `--clean` after a change under `render-wasm/`, after a dependency change, or when a killed build left bad artifacts.

**The container.** A container can be left attached to a Docker network that no longer exists. Compose then reuses the container by name, nginx dies on its first DNS lookup, and the container exits. `--recreate` removes the container before composing up, and every volume survives:

```sh
pdv run --recreate
```

When the container exits during a start, pdv reads the log and prints the diagnosis and the command. On a terminal it offers to run the removal for you.

## Everyday commands

```sh
pdv status                      # every instance, with its state, window set, and warnings
pdv status --ws 2               # one instance; a crashed one prints its state and a log tail
pdv seed                        # rebuild this instance's database from its profile
pdv seed status --ws 2          # the profile, hash, seeded-at, schema head, and files
pdv stop --watchers             # stop the three watcher windows, keep the instance
pdv start --watchers            # start them again in the same windows
pdv restart --services backend  # restart the backend process in its window and wait for it
pdv stop                        # stop the instance, through manage.sh stop-devenv; also removes a container already stopped
pdv attach                      # tmux inside the instance
pdv logs                        # follow the container log
```

`start` and `stop` with a selector act on windows, and `start` leaves a window that is already running alone. `stop` without a selector is the instance stop. No pdv verb attaches to a container to report a failure: a failed start reports the container's state and the last log lines, and a tmux session that does not appear within 120 seconds reports the last 40. `pdv status` also warns about a bind that a rename or a repointed slot has left behind, a stale compose label, and every pane of a pdv window that runs nothing.

## Develop against a running instance

These verbs act on the running instance that serves the worktree you call them from, so they need no `--ws` inside a worktree. When no instance serves it, they list what each running instance serves and exit 3. `--ws N` names one explicitly.

```sh
pdv testjvm start                                # a persistent backend test JVM, once per container
pdv testjvm run backend-tests.rpc-doc-test       # reload what changed, then run kaocha on the ids
pdv testjvm cold --focus backend-tests.rpc-doc-test   # a fresh JVM, as CI runs it
pdv eval '(+ 1 2)'                               # Clojure in the test JVM
pdv eval --target backend --file backend/src/app/rpc/commands/files.clj   # hot-load into the running backend
pdv repl                                         # cider-nrepl bridged to host port 6064 + 10000·N
pdv lsp                                          # clojure-lsp inside the instance, as an editor's server binary
pdv jobs 20                                      # the newest rows of the instance's job table
```

`pdv testjvm help` and `pdv eval --help` list the subcommands, flags, and exit codes. [The manual](docs/manual-pdv.md#the-development-tools-act-on-the-instance-that-serves-your-worktree) explains the lock, the reload, and when the test JVM needs a restart.

## The hygiene verbs

```sh
pdv acl                         # grant the container user write access to the tree
pdv tune                        # post-start fixes (config.js, clojure-lsp, skills link, cargo home) and the image check
```

## Troubleshooting

| symptom                                                                               | fix                                                                                                    |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| the main container is `Exited (1)` and the log ends with `host not found in upstream` | `pdv run --recreate`                                                                                   |
| `port is already allocated`                                                           | find the holder with `docker ps --format '{{.Names}} {{.Ports}}' \| grep <port>`, then stop that stack |
| the backend dies with an out-of-memory error                                          | `pdv run --java-opts "-Xmx1500m -Xms50m"`                                                              |
| the UI shows old code after a restart                                                 | wait for the first compile, or `pdv run --clean` when the cache is stale                               |
| a fresh worktree fails with `EACCES` in the watch panes                               | `pdv acl` grants the container user write access to the tree                                           |
| a watcher pane is idle after a restart                                                | `pdv start --watchers`, which installs missing node dependencies first                                 |
| a worktree's database has no fixtures, or the backend sits on another database        | `pdv seed --ws N` rebuilds the database and restarts the backend on it                                 |
| `.pdv-agent.json` is missing after a run                                              | `pdv seed --ws N`, and check that the profile marks an agent user                                      |
| `pdv testjvm run` or `pdv eval` exits 5 with `restart needed`                         | `pdv testjvm restart`, because the classpath, a reload-exempt namespace, or pdv's harness changed      |
| `pdv testjvm` or `pdv eval` exits 3 and lists the running instances                   | run it from the worktree an instance serves, or pass `--ws N`                                          |
| a backend change does not take effect and a reload cannot reach it                    | `pdv restart --services backend`                                                                       |

## The manual and the harness carry the detail

`pdv help` lists the commands and flags it owns. [The manual](docs/manual-pdv.md) explains the service model, the heap channel, the cache policy, the recreate path, the status warnings, the hygiene verbs, the development tools, and the parity harness. Much of what pdv does works around gaps in Penpot's devenv: [CONTRIBUTING.md](CONTRIBUTING.md) lists each workaround with the change that would move it into Penpot, and the checks a contribution passes.

The parity harness checks the contract in two modes. The offline mode reads the window plan, the service rules, the cache policy, the heap cap, and the seed naming rules out of the checkout and compares them with pdv's, and checks the development tools and the status warnings against a stub `docker`. The live mode brings the same workspace up with `pdv run` and with `./manage.sh run-devenv`, compares the two instances, and tears both down.

```sh
./test/parity.sh                       # offline: plan, services, caps, caches
./test/parity.sh --live --fast --ws 2  # a real instance, compared and torn down
```

pdv runs against a rootless or a rootful Docker daemon. When no rootful daemon is reachable, the harness reports that mode as a skip. Rootful verification is part of the upstream review, where reviewers run it on their own daemons.

## Credit

pdv takes its shape from Juanfran's [penpot-run-devenv-light](https://github.com/juanfran/penpot-run-devenv-light), a two-script launcher for a stock Penpot checkout. Thanks for the inspiration.
