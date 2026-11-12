---
genre: manual
---

# pdv runs one Penpot instance with the windows and the memory budget the work needs

The command is `pdv`, and it lives in this repository. `pdv help` lists the verbs and flags it owns. This manual states the intent behind them: which window a service owns, which channel carries the heap cap, what a restart costs, and what to do when a container will not come up.

## One command owns the window set, and manage.sh owns everything else

A Penpot development instance is a Docker container with a tmux session inside it. Upstream's `manage.sh run-devenv` creates that container and runs `start-tmux.sh`, which fixes the window set: the frontend watcher, Storybook, the exporter, the backend, and, in agentic mode, the MCP server and Serena. pdv takes the window set over, because the selection, the heap cap, and the cache policy all live in the command that starts a window.

Everything else stays upstream's. pdv loads `manage.sh` and calls its compose functions, so the ports, container names, volumes, network, and workspace paths come from the checkout rather than from a copy inside pdv. A verb pdv does not own is executed as `manage.sh <verb> <args>` with no translation. pdv calls no other script from the checkout: the two hygiene verbs, described later in this manual, are pdv's own code.

The parity harness checks that the arrangement holds.

## An instance is wsN, and ws0 binds the checkout pdv runs against

`--ws N` names the instance and works anywhere in the argument list. pdv reads the ceiling from `manage.sh` (`PENPOT_MAX_WS_INDEX`, currently 5), so it refuses an index whose published ports would overflow the 16-bit range with the same ceiling and reason `manage.sh` gives.

Instance ws0 binds the checkout pdv resolves: `--repo`, else `PENPOT_REPO`, else the Penpot worktree you call it from, else `~/Code/penpot`. Instance wsN binds `$PENPOT_WORKSPACES_DIR/wsN`, where the variable defaults to the XDG data directory when the legacy `~/.penpot/penpot_workspaces` does not exist. The slot wants a symlink to the worktree you mean:

```sh
ln -s ~/src/penpot-graph ~/.local/share/penpot-devenv/workspaces/ws2
```

A real directory in the slot makes `manage.sh` rsync a clone instead, and commits made in the clone have to be fetched back. `pdv run --ws 2` prints which case it found before the container starts.

An agent session reaches the instance in slot N through the ports `4401 + N × 10000` (Penpot MCP) and `14181 + N × 10000` (Serena). `./manage.sh start-coding-agent <client> --ws N` starts a coding agent with those ports wired into its MCP configuration.

## Instances share one database

Each workspace gets its own container, home volume, published ports, Redis index, and tenant. It does not get its own database or object store: `PENPOT_DATABASE_URI` points at one PostgreSQL database and the S3 object store is shared, so a user, a project, or a migration created in one instance is visible from every instance.

Every backend migrates that database at boot. Migration steps are keyed by module and step name, so an older branch starts normally against a schema that a newer branch migrated. The hazard is a later upstream migration that reuses a number with different SQL, because the step is skipped when the name already has a row. Watch for it when a rebase brings new migration files.

The test database is the exception: the instance overrides name `penpot_test` on ws0 and `penpot_test_wsN` on wsN.

## A service is a window, and storybook also names a compile target

`--services` takes a positive list. Each name is one window, and the windows appear in the order `frontend`, `storybook`, `exporter`, `backend`, `mcp`, `serena`. The default set is everything `start-tmux.sh` creates for the current mode, so a bare `pdv run` is the upstream instance.

`storybook` selects two things: its own window and the `storybook` target inside the frontend watcher. A selection that names `storybook` must also name `frontend`, and pdv refuses the list otherwise. `--watchers` is the `frontend,storybook,exporter` shorthand. `--only-backend` is `--services backend` under its old name.

`pdv start` and `pdv stop` toggling follow the same names. `stop --services frontend` sends an interrupt to the frontend window's panes and leaves the window and its shells in place. `start --services frontend` types the command back into the idle pane. A window that is absent is created at the next free index, so a backend-only instance can gain the exporter later. Before pdv starts a watcher it checks for `node_modules` in that service's tree and runs `./scripts/setup` when the directory is missing, because upstream installs those dependencies before its own windows exist and a backend-only run has not installed them.

`stop` without a selector is not a window verb. It stops the instance through `manage.sh stop-devenv`, which also stops the shared infrastructure when no other instance remains.

## The heap cap travels in `_JAVA_OPTIONS` because two scripts reset JAVA_OPTS

The default cap is `-Xmx768m -Xms50m`. pdv puts the cap in front of the `frontend`, `storybook`, `exporter`, and `backend` window commands, as both `_JAVA_OPTIONS` and `JAVA_OPTS`. Of those windows, the frontend, exporter, and backend start a Java Virtual Machine (JVM). The frontend window also carries the shadow-cljs process that compiles the storybook target.

The second variable is best effort. The image's `bashrc` exports `JAVA_OPTS` with a network flag and no `-Xmx`, and the backend's `scripts/_env` re-exports the same flags. A value passed in `JAVA_OPTS` alone therefore disappears before the JVM reads it. The JVM reads `_JAVA_OPTIONS` itself, after any script has run.

The cap reaches the window commands pdv sends, and not a release build or the test JVM. Release builds start with the JVM default heap. The test JVM starts with its own `-Xmx2g`.

`--java-opts` replaces the value, `DEVENV_JAVA_OPTS` sets the same value from the environment, and an explicitly empty value (`--java-opts ""`) removes the cap.

## A watcher restart keeps the caches, and --clean answers a toolchain change

Upstream's `./scripts/watch app` clears the shadow-cljs cache, runs `cargo clean` on the renderer crate, and rebuilds the Rust/WebAssembly (WASM) renderer before the watcher starts. The rebuild compiles Skia bindings and takes minutes, which makes every stop and start expensive.

pdv starts the same watcher without the clears. It runs `build:wasm` only when `frontend/resources/public/js/render-wasm.wasm` is missing, so the first run on a tree pays for the renderer and later runs do not.

`--clean` restores the upstream steps exactly: clear the shadow cache, clear the wasm build, rebuild the renderer. Reach for the flag after a change under `render-wasm/`, after a dependency change, or when a killed build left artifacts that the next compile cannot consume.

## A container on a dead network is the zombie that --recreate removes

Compose reuses a container by name. When the Docker network the container was attached to has gone, a `docker start` or a compose up keeps the container and gives it no working resolver. nginx then dies on its first lookup, and the log ends with:

```
[emerg] host not found in upstream "raw.githubusercontent.com" in /etc/nginx/nginx.conf
```

The network goes away after `manage.sh drop-devenv`, a Docker daemon restart, or another stack churning the bridge. `--recreate` removes the main container before composing up. The workspace is a bind mount, and the database and object store are named volumes, so all three live outside the container and survive.

`pdv run` reads the container log when the container exits during the start or the five-second settle that follows it. A log that carries that line gets the diagnosis and the exact `--recreate` command, and a terminal gets an offer to run the removal.

## Failures are reported in place, never through an attach

A container that cannot come up reports its state (`status`, `running`, `exit`, `error`) and the last 80 log lines. A tmux session that does not appear within 120 seconds prints the last 40 log lines. The same report appears in `pdv status` for an instance that is running but broken, which pdv measures by asking the container's health endpoint and by looking for the tmux session. No verb attaches to a session to show a failure, because the reader may not have a terminal that can host tmux.

A start waits for four things before it reports success: the container in the running state, a five-second settle after that, an answer from the health endpoint on port 8082, and the tmux session. The settle catches nginx dying just after Docker reports the container as running.

## Two hygiene verbs prepare the tree and the container

`pdv acl` grants the container user write access to the bound tree. Rootless Docker maps the image's `penpot` user to a subordinate uid, which the host treats as `other` on a tree the host user owns, so every dependency install in the watcher windows fails with `EACCES`. pdv measures that uid with a one-shot container, grants it a read-write ACL and a default ACL on every entry the host user owns, and proves the grant by writing from inside a container. A rootful daemon maps the uid one to one, and the verb then reports that it has nothing to grant. `run` applies the grant before every start. A wsN slot that `manage.sh` fills with a copy does not exist before the first start, so grant the copy with `pdv acl --ws N` once it exists, or symlink a worktree into the slot beforehand.

`pdv tune` runs after every start and is safe to run again. It hands the image's root-owned Cargo home (`/opt/cargo`) to the container user, because a render-wasm build that must fetch a crate missing from the vendored set otherwise fails with `Permission denied`. It also compares the running container's image with the local image and the local image with the registry, and prints the adoption command when either is stale.

## The parity harness is the net every behaviour change lands behind

`test/parity.sh` has two modes. The offline mode reads the window plan out of the checkout's own `start-tmux.sh` and compares it with pdv's plan, then asserts the service rules, the cache policy, and the heap cap without touching a container. The live mode brings the same workspace up twice, with `pdv run` and with `./manage.sh run-devenv`, and compares the container state, the published ports, the mounts, and the tmux window set. A bare `pdv run` claims to be the upstream instance, so upstream is the reference. pdv runs first, because its ACL grant is what lets the upstream instance build on a rootless daemon. With `--fast`, the live mode also proves that `--recreate` keeps every named volume, that a JVM carries the cap in its environment, and that `status` reports a stopped instance.

The live mode runs in agentic mode by default, so pass `--plain` when `frontend/resources/public/js/config.js` is absent.

The live mode removes the instance's container before each recording. Run it against a workspace nobody is using, never against an instance you are working in.

pdv runs against a rootless or a rootful Docker daemon. `--rootful` points the run at `/var/run/docker.sock` through `DOCKER_HOST`, and the harness reports a skip when no rootful daemon exists. Rootful verification belongs to the upstream review, where reviewers run it on their own daemons. The chosen workspaces must be stopped on the rootless daemon first, because both daemons publish the same host ports.

## pdv deletes no volumes and builds no images

pdv never deletes a named volume. `--recreate` removes a container and leaves its volumes. `pdv stop` runs `manage.sh stop-devenv`, which removes the containers and keeps their volumes. `pdv run --ws N` creates or syncs the wsN slot on first use, and no pdv verb deletes the slot.

The image is upstream's business. `./manage.sh pull-devenv` fetches it, `./manage.sh build-devenv` builds it locally, and `./manage.sh drop-devenv` removes it on a full teardown. A stale image shows up as a toolchain mismatch or a missing command inside the container, and the fix is a pull followed by a stop and a run.
