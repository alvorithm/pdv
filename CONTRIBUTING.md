# Contributing to pdv

pdv sits on top of Penpot's `manage.sh` and its devenv image. Part of what pdv does belongs in Penpot itself, and pdv carries it only until Penpot does. This document states the rules every change follows and, for each workaround, the form it would take in a pull request to Penpot.

## Every change passes the same checks

- A behaviour change lands with the parity harness covering it. `test/parity.sh` runs offline by default. `test/parity.sh --live --fast --ws N` adds the comparison with `./manage.sh run-devenv` on a real instance. The live mode removes the instance's container, so point it at a workspace nobody is using.
- pdv never restates the compose environment that `manage.sh` computes. pdv loads `manage.sh` and calls its functions, and a verb pdv does not own falls through to `manage.sh` unchanged.
- pdv depends only on the checkout's `manage.sh`, the files tracked in the Penpot repository, the devenv image, and bash, coreutils, `curl` and Docker on the host. It calls no untracked helper from the checkout, so it runs on a stock clone.
- The README and the manual carry the user-facing surface. A flag that changes behaviour changes them in the same commit.
- Scripts need bash 4 or newer and pass `bash -n`.
- A new workaround gets its own section below, naming the pdv code and the upstream form.

## Each workaround has an upstream form

A workaround compensates for something in the Penpot repository or the devenv image. Each section below names the pdv code that carries the workaround today and the change that would make it unnecessary. Once such a change is on Penpot's `develop` branch, pdv deletes the workaround, and the parity harness proves that the result still matches `manage.sh`.

The upstream changes are independent of each other. Each one can be a separate pull request, in any order.

### The window set follows a service list

pdv today: `start-tmux.sh` (in `docker/devenv/files/`) always creates the same windows, so pdv builds its own window plan from `--services` (`lib/pdv-services.sh`). Selecting `storybook` also restores the storybook compile target in the frontend watcher.

In Penpot: `start-tmux.sh` reads a service list from the environment, and `manage.sh run-devenv` gains `--services`. The storybook pairing rule moves with it. pdv then passes the list through and drops its window plan.

### The heap cap travels in JAVA_OPTS

pdv today: pdv puts the cap (default `-Xmx768m -Xms50m`) in `_JAVA_OPTIONS`, because `docker/devenv/files/bashrc` and `backend/scripts/_env` both assign `JAVA_OPTS` and discard any value set before them.

In Penpot: both scripts append to an existing `JAVA_OPTS` instead of replacing it, and `manage.sh` sets a default cap that `defaults.env` can override. pdv then sets `JAVA_OPTS` only.

### A watcher restart keeps its caches

pdv today: `watch:app` in `frontend/package.json` runs `clear:shadow-cache`, `clear:wasm`, and `build:wasm` before every watcher start, and the wasm rebuild takes minutes. pdv starts the same watcher processes without those steps, builds wasm only when `render-wasm.wasm` is missing, and restores the full sequence with `--clean`. Because pdv starts those processes directly instead of through `./scripts/watch`, it also runs `./scripts/setup` first when the service's `node_modules` is missing.

In Penpot: `watch:app` keeps the caches and builds wasm only when its artifact is missing, and a separate `watch:app:clean` script runs the full sequence. pdv then calls `./scripts/watch app` like every other window, the script's own `pnpm install` covers the dependencies, and the `node_modules` check goes away.

### A container on a dead network is recreated

pdv today: when the Docker network a container was attached to has gone, compose reuses the container by name and nginx dies on its first lookup. pdv recognizes the signature in the log, prints the diagnosis, and offers `--recreate`, which removes the container and keeps its volumes.

In Penpot: `manage.sh run-devenv` checks that the networks of an existing main container still exist and recreates the container when one is missing.

### A failed start reports itself without an attach

pdv today: a start waits for the running state, a five-second settle, the health endpoint, and the tmux session, and prints the container state and a log tail when any of them fails. `pdv status` lists every instance with its state, ports, tree, branch, and windows, and reports a container that exited with 0 or 143 as stopped rather than broken.

In Penpot: `manage.sh run-devenv` performs the same waits and reports, and a new `status-devenv` verb lists the instances. The same verb can feed a status widget.

### A stop removes a container that is already stopped

pdv today: `manage.sh stop-devenv` brings down only the instances that `list-running-instances` returns, which reads `docker ps`. A container stopped outside the devenv, by a Docker daemon restart or a host shutdown, is therefore never removed. Before it calls `manage.sh`, `pdv stop` passes each target main container that exists and is not running to `manage.sh`'s `stop-instance` (`lib/pdv-core.sh::remove_stopped_instances`).

In Penpot: `stop-devenv` selects its targets from `docker ps -a`, so `--all` and `--ws N` bring down every instance whose main container exists, running or not. pdv then drops the pre-step.

### Each worktree gets its own database and bucket

pdv today: every instance shared the `penpot` database and the `penpot` bucket, because `docker/devenv/defaults.env` sets one `PENPOT_DATABASE_URI` and one bucket for all of them, and `manage.sh::instance-env-overrides` overrides only the test database per instance. Two worktrees on branches with different migrations then ran against one schema. pdv now names both after the bound worktree's directory, not the ws number: the basename is lower-cased, every run of characters outside `a-z0-9` becomes `_`, the result is trimmed and cut to 40 characters, and the database is `pdvwt_<slug>` with the bucket `pdvwt-<slug>`. `--db NAME` overrides both and is remembered per worktree. `--db penpot` is the shared database, which pdv never creates, seeds, drops or sweeps. Before the start pdv creates the database the way `manage.sh::ensure-instance-test-database` creates the test database, with a `pdv_meta` row carrying the worktree path, and a database whose worktree is gone is dropped with its bucket by a sweep at `pdv run` and before `pdv stop --all`. It passes `PENPOT_DATABASE_URI` and `PENPOT_OBJECTS_STORAGE_S3_BUCKET` as a prefix of the backend window command (`lib/pdv-services.sh::backend_prefix`), the channel the heap cap already uses, and sets both in the tmux session environment so that later panes inherit them. `backend/scripts/_env::setup_s3_bucket` creates the bucket at start. The fixtures are staged by `share/pdv-seed.bb` inside the container and imported by `share/seed.clj`, which pdv installs over the backend's prepl socket, from named profiles in a separate private repository (`~/Code/penpot-fixtures`, or `PDV_FIXTURES`). Every import is recorded with its hash, so a re-run imports nothing and a changed profile rebuilds the database before the backend starts (`lib/pdv-seed.sh`). pdv writes no file into the checkout: the profile and the database choice live in the worktree's own git directory, and the one file it writes into the tree, `.pdv-agent.json`, is listed in `info/exclude`. No overlay is needed, and a developer's own `backend/scripts/_env.local` stays in charge: a value that file exports wins. A shell opened with `docker exec` still sees the shared defaults, so pdv's own verbs that reach the database pass the name explicitly. The programme is `dv:extras:pdv-seeds-each-worktree-database-from-shared-fixtures`.

In Penpot: `manage.sh run-devenv` takes an opt-in `--database NAME`. `instance-env-overrides` then sets `PENPOT_DATABASE_URI` and `PENPOT_OBJECTS_STORAGE_S3_BUCKET` for that instance, which reaches the whole container through compose, and a generalized `ensure-instance-database` creates the database as the test database is created today. `scripts/psql` learns the instance's database as it already knows the instance's test database. The shared database stays the default, as the comment in `docker-compose.main.yml` intends. pdv then passes the flag and drops the prefix and the tmux environment.

### safe.directory is added once

pdv today: `manage.sh` appends a `safe.directory` entry to the global git configuration on every run, so pdv hands it a disposable copy through `GIT_CONFIG_GLOBAL`.

In Penpot: the open pull request penpot/penpot#12667 adds the entry only when it is missing. Once that change is on `develop`, pdv drops the copy.

### Rootless Docker gets its ACL before the start

pdv today: rootless Docker maps the container user to a subordinate uid, which cannot write a tree the host user owns, so the first `pnpm install` fails with `EACCES`. `pdv acl` measures that uid with a one-shot container and grants it an ACL on the tree before every start (`lib/pdv-core.sh::grant_acl`).

In Penpot: `manage.sh run-devenv` runs the same grant before it composes the container up. The grant is a no-op on rootful Docker.

### The Cargo home belongs to the container user

pdv today: the image creates `/opt/cargo` as root, so a render-wasm build that needs a crate missing from the vendored set fails with `Permission denied`. `pdv tune` hands the directory to the container user after every start.

In Penpot: `docker/devenv/Dockerfile` changes the owner of `/opt/cargo` to the container user after vendoring.

### A stale image is reported at start

pdv today: `pdv tune` compares the running container's image with the local image, and the local image with the registry, and prints the update command when either is stale.

In Penpot: `manage.sh run-devenv` prints the same advisory.

### config.js comes from PENPOT_FLAGS

pdv today: the agentic frontend enables MCP only through `frontend/resources/public/js/config.js`. The file is gitignored, and a frontend build deletes it along with the rest of `resources/public`. `pdv tune` keeps a snapshot of the file in the instance's home volume and restores it when it is gone, or writes it from `PDV_PENPOT_FLAGS` plus `disable-admin-console` (see the next section). `pdv run --agentic` does the same before the start, where `manage.sh` refuses to run.

In Penpot: the devenv generates the file from `PENPOT_FLAGS` at start, as `docker/images/files/nginx-entrypoint.sh` already does for the production images, and the agentic pre-flight in `manage.sh` goes away. pdv then drops the snapshot and its variable.

### The admin-console is off in the devenv

pdv today: the backend turns the admin-console (Nitrate) module on by default, and no devenv runs the service, so every profile read fails with "nitrate is unreachable". pdv starts the backend with `disable-admin-console` prepended to `PENPOT_FLAGS` (`lib/pdv-services.sh::backend_prefix`), and a `config.js` it generates carries the same flag for a frontend that predates penpot#13061.

In Penpot: `backend/scripts/_env` applies the default penpot#13061 gave the frontend: with `PENPOT_DEVENV=true`, which `docker-compose.main.yml` already sets, it prepends `disable-admin-console` to the backend flags, and `enable-admin-console` in `_env.local` turns the module back on. pdv then drops the prefix. The `config.js` flag goes once no supported branch predates penpot#13061.

### The clojure-lsp setting is committed

pdv today: the `sv/defmethod` hook declares a var per RPC handler that only runtime dispatch resolves, so clojure-lsp reports every handler as an unused public var, and no clj-kondo setting reaches that linter. `pdv tune` installs `share/clojure-lsp-config.edn`, which turns the linter off, into the container home.

In Penpot: the repository commits a project `.lsp/config.edn` with the same setting, which fixes every editor inside and outside the container. pdv then drops the file and its tune step.

### The skills link is committed

pdv today: Claude Code reads skills only from `.claude/skills`, and the repository keeps them in `.agents/skills`. `manage.sh` creates the link in wsN copies only, so `pdv tune` creates `.claude/skills -> ../.agents/skills` in the bound tree when the path is free.

In Penpot: the repository commits the symlink. Git cannot re-include a path under an ignored directory, so `.gitignore` changes `/.claude` to `/.claude/*` plus `!/.claude/skills`. The seeding in `manage.sh` and the tune step both go away.

### Terminal preferences live in the home volume

pdv today: the image ships `tmux.conf` with the mouse off, and its entrypoint copies the file over `~/.tmux.conf` on every start. With `PDV_TMUX_MOUSE=1`, `pdv tune` turns the mouse on in the running session.

In Penpot: the image's `tmux.conf` ends with `source-file -q ~/.tmux.conf.local`. That file lives in the home volume, survives a recreate, and holds each developer's own settings, so pdv drops its variable. The same change is the moment to offer zellij beside tmux: its layouts are declarative KDL files that could replace the imperative `start-tmux.sh`, and a variable such as `PENPOT_MULTIPLEXER` would select it, with tmux as the default. That option needs zellij in the image, and a port of the `tmux send-keys` calls in `start-tmux.sh` and pdv and of pdv's `tmux list-windows` calls.

## The implementation language is open

pdv is written in bash, and the next step is a port to a language with real argument parsing and data structures. Babashka is the current candidate: the devenv image already ships it, and Penpot already runs Babashka scripts. Python is the alternative, because practically every Linux host has it and `manage.sh` already requires it on the host to build the MCP client configuration. A port can move one command at a time and call the remaining bash until none is left. The parity harness judges either port by the same checks.
