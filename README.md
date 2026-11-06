# pdv

Penpot's `manage.sh run-devenv` starts four windows at once: the frontend watcher, Storybook, the exporter, and the backend, plus the MCP and Serena windows in agentic mode. On a laptop, four windows mean more heap and more compiling than the work needs. pdv starts the windows you name, caps the heap of the three JVMs those windows start, and keeps the compile caches between restarts.

pdv owns the instance bring-up and the window set. It also carries the verbs that act on a running instance: `acl`, `tune`, `slim`, `fatten`, `jobs`, `report`, `repl`, `testjvm`, and `eval`. Any other `manage.sh` verb runs unchanged, so `pdv pull-devenv` is `manage.sh pull-devenv` and an upstream flag works here on the day it lands.

## Requirements

- Docker, rootless or rootful, with the Penpot devenv image (`./manage.sh pull-devenv`).
- A Penpot checkout that carries `manage.sh`.
- bash 4 or newer on the host.

## Install

Copy or clone this repository to `~/Code/pdv`, then link the command onto your PATH:

```sh
ln -s ~/Code/pdv/pdv ~/.local/bin/pdv
```

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
pdv status                      # every instance, with its state and window set
pdv status --ws 2               # one instance, and a broken one prints its state and a log tail
pdv stop --watchers             # stop the three watcher windows, keep the instance
pdv start --watchers            # start them again in the same windows
pdv stop                        # stop the instance, through manage.sh stop-devenv
pdv attach                      # tmux inside the instance
pdv logs                        # follow the container log
```

`start` and `stop` with a selector act on windows. `stop` without a selector is the instance stop. No pdv verb attaches to a container to report a failure: a failed start reports the container's state and the last log lines, and a tmux session that does not appear within 120 seconds reports the last 40.

## The instance verbs

```sh
pdv slim                        # stop the watcher windows, keep the backend
pdv fatten                      # bring them back in the same windows
pdv tune                        # post-start hygiene, safe to rerun
pdv acl                         # grant the container user write access to the tree
pdv testjvm start               # a persistent backend test JVM
pdv eval '(+ 1 2)'              # evaluate Clojure in that JVM
pdv repl                        # the nREPL bridge for editors
pdv jobs 20                     # the instance's job-table rows
pdv report                      # the bug-reporter checklist
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

## The manual and the harness carry the detail

`pdv help` lists the commands and flags it owns. [The manual](docs/manual-pdv.md) explains the service model, the heap channel, the cache policy, the recreate path, the instance verbs, and the parity harness.

The parity harness checks the contract in two modes. The offline mode reads the window plan, the service rules, the cache policy, and the heap cap out of the checkout and compares them with pdv's. The live mode compares a real pdv instance with a reference instance of the same workspace and tears both down.

```sh
./test/parity.sh                       # offline: plan, services, caps, caches
./test/parity.sh --live --fast --ws 2  # a real instance, compared and torn down
```

pdv runs against a rootless or a rootful Docker daemon. When no rootful daemon is reachable, the harness reports that mode as a skip. Rootful verification is part of the upstream review, where reviewers run it on their own daemons.

## Credit

pdv takes its shape from Juanfran's [penpot-run-devenv-light](https://github.com/juanfran/penpot-run-devenv-light), a two-script launcher for a stock Penpot checkout. Thanks for the inspiration.
