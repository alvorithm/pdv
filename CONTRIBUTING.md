# Contributing to pdv

pdv sits on top of Penpot's `manage.sh` and its devenv image. Part of what pdv does belongs in Penpot itself, and pdv carries it only until Penpot does. This document states the rules every change follows and, for each workaround, the form it would take in a pull request to Penpot.

## Every change passes the same checks

- A behaviour change lands with the parity harness covering it. `test/parity.sh` runs offline by default. `test/parity.sh --live --fast --ws N` adds the comparison with `./manage.sh run-devenv` on a real instance. The live mode removes the instance's container, so point it at a workspace nobody is using.
- pdv never restates the compose environment that `manage.sh` computes. pdv loads `manage.sh` and calls its functions, and a verb pdv does not own falls through to `manage.sh` unchanged.
- pdv depends only on the checkout's `manage.sh`, the files tracked in the Penpot repository, and the devenv image. It calls no untracked helper from the checkout, so it runs on a stock clone.
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

pdv today: `watch:app` in `frontend/package.json` runs `clear:shadow-cache`, `clear:wasm`, and `build:wasm` before every watcher start, and the wasm rebuild takes minutes. pdv starts the same watcher processes without those steps, builds wasm only when `render-wasm.wasm` is missing, and restores the full sequence with `--clean`.

In Penpot: `watch:app` keeps the caches and builds wasm only when its artifact is missing, and a separate `watch:app:clean` script runs the full sequence. pdv then calls `./scripts/watch app` like every other window.

### A window installs its own dependencies

pdv today: because pdv starts the frontend watcher processes directly instead of through `./scripts/watch`, it runs `./scripts/setup` first when the service's `node_modules` is missing.

In Penpot: nothing beyond the cache change above. Once pdv calls `./scripts/watch app`, the script's own `pnpm install` covers the dependencies, and the check goes away.

### A container on a dead network is recreated

pdv today: when the Docker network a container was attached to has gone, compose reuses the container by name and nginx dies on its first lookup. pdv recognizes the signature in the log, prints the diagnosis, and offers `--recreate`, which removes the container and keeps its volumes.

In Penpot: `manage.sh run-devenv` checks that the networks of an existing main container still exist and recreates the container when one is missing.

### A failed start reports itself without an attach

pdv today: a start waits for the running state, a five-second settle, the health endpoint, and the tmux session, and prints the container state and a log tail when any of them fails. `pdv status` lists every instance with its state, ports, tree, branch, and windows.

In Penpot: `manage.sh run-devenv` performs the same waits and reports, and a new `status-devenv` verb lists the instances. The same verb can feed a status widget.

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

pdv today: the agentic frontend enables MCP only through `frontend/resources/public/js/config.js`. The file is gitignored, and a frontend build deletes it along with the rest of `resources/public`. `pdv tune` keeps a snapshot of the file in the instance's home volume and restores it when it is gone, or writes it from `PDV_PENPOT_FLAGS`. `pdv run --agentic` does the same before the start, where `manage.sh` refuses to run.

In Penpot: the devenv generates the file from `PENPOT_FLAGS` at start, as `docker/images/files/nginx-entrypoint.sh` already does for the production images, and the agentic pre-flight in `manage.sh` goes away. pdv then drops the snapshot and its variable.

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

