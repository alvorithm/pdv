---
genre: manual
---

# pdv runs one Penpot instance with the windows and the memory budget the work needs

The command is `pdv`, and it lives in this repository. `pdv help` lists the verbs and flags it owns. This manual states the intent behind them: which window a service owns, which database and bucket a worktree writes to, which channel carries the heap cap, what a restart costs, how tests and editors reach a running backend, and what to do when a container will not come up.

## One command owns the window set, and manage.sh owns everything else

A Penpot development instance is a Docker container with a tmux session inside it. Upstream's `manage.sh run-devenv` creates that container and runs `start-tmux.sh`, which fixes the window set: the frontend watcher, Storybook, the exporter, the backend, and, in agentic mode, the MCP server and Serena. pdv takes the window set over, because the selection, the heap cap, and the cache policy all live in the command that starts a window.

Everything else stays upstream's. pdv loads `manage.sh` and calls its compose functions, so the ports, container names, volumes, network, and workspace paths come from the checkout rather than from a copy inside pdv. A verb pdv does not own is executed as `manage.sh <verb> <args>` with no translation. pdv calls no other script from the checkout: the hygiene verbs and the development tools, described later in this manual, are pdv's own code. The code that runs inside the container lives in pdv's `share/` directory and travels as `docker exec` arguments, because pdv's checkout is not mounted there.

The parity harness checks that the arrangement holds.

## An instance is wsN, and ws0 binds the checkout pdv runs against

`--ws N` names the instance and works anywhere in the argument list. pdv reads the ceiling from `manage.sh` (`PENPOT_MAX_WS_INDEX`, currently 5), so it refuses an index whose published ports would overflow the 16-bit range with the same ceiling and reason `manage.sh` gives.

Instance ws0 binds the checkout pdv resolves: `--repo`, else `PENPOT_REPO`, else the Penpot worktree you call it from, else `~/Code/penpot`. Instance wsN binds `$PENPOT_WORKSPACES_DIR/wsN`, where the variable defaults to the XDG data directory when the legacy `~/.penpot/penpot_workspaces` does not exist. The slot wants a symlink to the worktree you mean:

```sh
ln -sn ~/src/penpot-graph ~/.local/share/penpot-devenv/workspaces/ws2
```

A real directory in the slot makes `manage.sh` rsync a clone instead, and commits made in the clone have to be fetched back. `pdv run --ws 2` prints which case it found before the container starts.

An agent session reaches the instance in slot N through the ports `4401 + N × 10000` (Penpot MCP) and `14181 + N × 10000` (Serena). `./manage.sh start-coding-agent <client> --ws N` starts a coding agent with those ports wired into its MCP configuration.

Every instance shares one postgres, one object store, and the other infra services. The checkout that started postgres owns it, because postgres mounts its configuration from that checkout. A `pdv run` from another checkout starts only the services that are missing and never recreates a running one, so the backends already connected keep their connections. The configuration of another checkout takes effect only after every instance has stopped and the infra has come down. The exception is an owner whose files are gone, as after `git worktree remove`: pdv warns and recreates postgres from the current checkout, because the old container could not start again.

## Each worktree gets its own database and bucket

Every instance used to share the `penpot` database and the `penpot` bucket that `docker/devenv/defaults.env` configures, so two worktrees on branches with different migrations ran against one schema. pdv now gives each bound worktree a database and a bucket of its own.

The name comes from the worktree directory, not from the ws number: the basename is lower-cased, every run of characters outside `a-z0-9` becomes `_`, the result is trimmed of `_` and cut to 40 characters, and the database is `pdvwt_<slug>` with the bucket `pdvwt-<slug>`. `penpot-iop-vc-preview` therefore becomes the database `pdvwt_penpot_iop_vc_preview` and the bucket `pdvwt-penpot-iop-vc-preview`. The worktree directory is the one the container binds, so a wsN slot that symlinks a worktree is named after the worktree, while a real directory in the slot is named after the slot.

### A profile is what goes into the database

A profile is one YAML file in the fixture repository, `$PDV_FIXTURES/profiles/<name>.yaml` (`PDV_FIXTURES` defaults to `~/Code/penpot-fixtures`). It lists these keys:

- `users`: every account with its `email` and `fullname`, an optional `password` (default `123123`), an optional `password_file` naming a host JSON file whose `password` field wins, and `agent: true` for the account pdv mints an access token for.
- `teams`: every team with its members and each member's role (`owner`, `admin`, `editor`, or `viewer`).
- `bundles`: the files to import, each one either a path in the fixture repository or a source such as `git+https://github.com/<owner>/<repo>@<rev>#<path>`, with an optional team and project.
- `generators`: programs in the repository that create files, with their arguments and target project.
- `backend_heap`: an optional `-Xmx` size such as `"2g"` for the backend JVM, for profiles that import hub files (see "The heap cap travels in `_JAVA_OPTIONS`").
- `keep_going`: `true` for a profile whose failures are the result, such as the fixture repository's `legacy-files` (see "A keep_going seed tries every item").

The driver `share/pdv-seed.bb` runs in the container and stages what the profile names. The engine `share/seed.clj` is loaded into the running backend, where it creates the users, teams, and files with Penpot's own commands, imports each bundle, and records every import with its hash. A project a seed creates is named `<project> · schema <migration number>`, for example `branch-id-reroute · schema 0808`, so a fixture states which schema it was made against. The database's `migrations` table holds the full name of that step.

```sh
pdv run --seed branching              # profiles/branching.yaml seeds this worktree
pdv run --seed none                   # forget the name: the default profile applies
PDV_SEED_DEFAULT=branching pdv run    # the profile for every worktree that chose none
```

Without a named profile the database still gets pdv's built-in one, `share/default-profile.yaml`: `zeus@penpot.app` owns the team "Work on this worktree", `aeolus@penpot.app` is an editor whose token pdv mints, and nothing is imported. That file is also the shortest working example of the profile schema. Every shipped profile writes the passwords inline, because a devenv database is disposable and `123123` reaches any seeded account in a demo. `password_file` stays in the schema for whoever wants a password out of the repository.

Names carry intent and a date, because they are how the next person or agent finds a fixture: a project is `<YYYYMMDD> <Area>: <what it shows>`, a bundle is `bundles/<area>/<YYYYMMDD>-<what-it-shows>.penpot`, and a team names the profile's purpose. The driver prints a `naming:` line for a project outside that pattern, and `pdv bundle save` warns about a path without the date. Neither refuses anything. The fixture repository's README carries the full scheme with examples.

Log in to a seeded instance as `zeus@penpot.app` with `123123`, and let an agent read `.pdv-agent.json` for `aeolus@penpot.app` and its token. No address at `penpot.app` receives mail from a devenv, because the devenv's SMTP goes to the mailpit container.

A developer who wants their own default for every worktree writes it once in `${XDG_CONFIG_HOME:-~/.config}/pdv/env`, one `PDV_NAME=value` per line, for example `PDV_SEED_DEFAULT=default` and `PDV_FIXTURES=~/Code/penpot-fixtures`. pdv reads only `PDV_*` names there, expands a leading `~/`, and lets the environment override the file.

The name is remembered in the worktree's own git directory, in a file called `pdv-seed`, so it belongs to that worktree and never shows in `git status`. An explicit `--db NAME` is remembered the same way in `pdv-db`.

### The database lives as long as its worktree

`pdv run` creates the database before the backend starts, the way `manage.sh::ensure-instance-test-database` creates the test database, and records `worktree_path` and `created_at` in a `pdv_meta` table. The backend's migrations ignore a table they do not know. The bucket is created by `backend/scripts/_env::setup_s3_bucket` when the backend starts.

The seed itself runs after the backend answers: pdv waits for the backend's nREPL on port 6064 inside the container, then for the applied migrations to settle, then applies the profile through that nREPL. Port 6063 is Penpot's JSON command REPL (`app.srepl/json-repl`), which takes one JSON command per line and cannot evaluate Clojure forms.

A second run with the same profile imports nothing. pdv computes an input hash over the profile text, every staged fixture file, and every remote source, and compares it with the hash the last seed recorded. When it differs, pdv drops the database, empties the bucket, recreates the database, and only then starts the backend, because an import always assigns new file ids and a merge into the old database would leave both sets behind.

A `git+` source resolves through GitHub's trees API, which allows 60 calls an hour without `GITHUB_TOKEN`. The driver fetches each repository's tree once per revision and looks every path up in it, so a profile that pins 17 files at one commit costs one call each time pdv stages it. `PDV_SEED_DEBUG=1` makes the driver print each trees API call on stderr.

The database survives `pdv stop`. It disappears with the worktree: before a `pdv run` and before `pdv stop --all` brings the shared infrastructure down, pdv sweeps the `pdvwt_*` databases whose recorded `worktree_path` no longer exists and removes their buckets. The sweep is best effort, so an unreachable postgres or object store warns and the rest of the command continues. What is not exported disappears with the worktree.

```sh
pdv seed                    # rebuild this instance's database and seed it again
pdv seed branching          # switch the profile, then rebuild
pdv seed status             # profile, hash, seeded-at, schema head, files per source, failed items
pdv seed verify             # open every seeded file with this tree's code, one verdict per file
pdv bundle save bundles/branching/review-pair.penpot --project review-pair
```

`pdv seed` is the manual rebuild: it stops the backend window, drops and recreates the database, empties the bucket, starts the backend again, and seeds. `pdv bundle save` exports a project, libraries included, into the fixture repository and prints the `git add` and `git commit` commands. It never commits.

### A keep_going seed tries every item

By default the first bundle or generator that throws aborts the seed: the items before it are imported, the items after it are never tried, and `pdv seed` exits 1. With `keep_going: true` the engine catches the failure of each item, records it in `pdv_seed_file` with the verdict `failed` and an error that holds the message, the code, and the schema paths of the refused values with every uuid removed, and carries on with the next item. The driver then prints one row per bundle and generator:

```text
  SOURCE                             FILE                        VERDICT   ERROR
  Avataaars-by-Pablo-Stanley.penpot  Avataaars-by-Pablo-Stanley  failed    [:pages-index :objects :svg-attrs :filter]
  welcome.penpot                     #8138 file                  imported  -
```

A seed with failed items exits 3, which means the database is seeded and usable. `pdv seed` exits 3 as well, `pdv run` prints the table and keeps the backend up, and `pdv seed status` lists the failed items after the files. The seed still records its input hash, so the next `pdv run` keeps the database and tries each failed item again without a rebuild. The key stays out of the input hash, so switching it on or off never rebuilds the database.

### pdv seed verify opens every seeded file with the tree's current code

An import tests only the files that arrive through an import. A user's file sits in the database at the schema of the version that wrote it, and the next version migrates it when someone opens it. To test that case, seed on the release tree users run, switch the worktree to the branch, restart the backend, and run `pdv seed verify`. The profile and its input hash do not change with the branch, so `pdv run` keeps the database, and the backend applies the branch's database migrations on start. The seed engine loads on `main` (the 2.19 release), on `develop`, and on `iop-vc-preview`.

For every file id that `pdv_seed_file` records, from bundles and generators alike, verify calls `app.binfile.common/get-file` with `:read-only? true` in a read-only transaction that rolls back, then `app.common.files.validate/validate-file-schema!` on the result, because a read does not check a file that needs no migration. A read-only read migrates in memory and runs the same data check a migration ends with, but writes nothing, so each file keeps its `revn` and its recorded migrations and a second run tests the same stored state. Verify prints one row per file (project, file name, verdict, and the schema paths of a failure) and exits 3 when any file fails.

The fixture repository's `legacy-files` profile serves a branch that changes what old files must pass: 17 hub files pinned at one penpot-files commit, and a generator that writes the file of penpot/penpot#13107, which no export can carry. `pdv seed legacy-files` on the branch is the import run. A seed on the release tree, a switch to the branch, and `pdv seed verify` are the upgrade run.

### The backend window carries the database and the bucket

The backend window command starts with `PENPOT_DATABASE_URI=postgresql://postgres/<db>` and `PENPOT_OBJECTS_STORAGE_S3_BUCKET=<bucket>`, beside the heap cap and the admin-console flag, and pdv sets both in the tmux session environment. A pane that restarts `./scripts/start-dev` by hand therefore lands on the same database and bucket the window would.

After a seed that has an agent user, pdv copies the credentials out to `<tree>/.pdv-agent.json`, mode 600, and adds `/.pdv-agent.json` to `<git-common-dir>/info/exclude` so it never appears in `git status`. The file holds the URL, the account's email, its access token, and the database name.

### `--db penpot` is the escape to the shared database

The shared database is the one the devenv's Postgres creates on its first start, and `pdv run --db penpot` uses it with the `penpot` bucket. pdv never creates, seeds, drops or sweeps it, so an instance on it behaves exactly as every instance did before this change: a user, a project, or a migration created in one instance is visible from every instance that shares it. Reach for it when data must cross instance boundaries, and for anything else prefer the worktree's own database. Once nobody needs it, `DROP DATABASE penpot` frees it, and from then on `--db penpot` fails, because nothing recreates it.

The migration hazard lives there. Every backend migrates that one schema at boot, migration steps are keyed by module and step name, so an older branch starts normally against a schema that a newer branch migrated. The risk is a later upstream migration that reuses a number with different SQL, because the step is skipped when the name already has a row. Watch for it when a rebase brings new migration files.

The test database is separate either way: the instance overrides the name `penpot_test` on ws0 and `penpot_test_wsN` on wsN.

## A service is a window, and storybook also names a compile target

`--services` takes a positive list. Each name is one window, and the windows appear in the order `frontend`, `storybook`, `exporter`, `backend`, `mcp`, `serena`. The default set is everything `start-tmux.sh` creates for the current mode, so a bare `pdv run` is the upstream instance.

`storybook` selects two things: its own window and the `storybook` target inside the frontend watcher. A selection that names `storybook` must also name `frontend`, and pdv refuses the list otherwise. `--watchers` is the `frontend,storybook,exporter` shorthand. `--only-backend` is `--services backend` under its old name.

`pdv start` and `pdv stop` toggling follow the same names. `stop --services frontend` sends an interrupt to the frontend window's panes and leaves the window and its shells in place. `start --services frontend` types the command back into the idle pane, and leaves a pane that is already running alone. A window that is absent is created at the next free index, so a backend-only instance can gain the exporter later. Before pdv starts a watcher it checks for `node_modules` in that service's tree and runs `./scripts/setup` when the directory is missing, because upstream installs those dependencies before its own windows exist and a backend-only run has not installed them.

`pdv restart --services LIST` stops the named windows and then starts them, which is the way to restart a running backend after a change that a reload cannot reach. The restart is a full process restart in the window, never `(app.main/restart)`, because the in-JVM refresh reloads vendored promesa under live channels and can park the msgbus loop, after which graph sync, websocket notifications, and realtime collaboration stay dead. When `backend` is among the names, the verb waits up to 300 seconds for the new process to open its nREPL on port 6064.

`stop` without a selector is not a window verb. It stops the instance through `manage.sh stop-devenv`, which also stops the shared infrastructure when no other instance remains. `manage.sh` stops only running instances, so a container that stopped outside pdv (a Docker daemon restart, a host shutdown) would stay forever. pdv therefore first removes the target's main container when it exists and is not running, through `manage.sh`'s own `stop-instance`, and `--all` does the same for every devenv container on the daemon. Volumes stay.

## Backend-only work stops the watchers, and the UI then serves the bundle on disk

The shadow-cljs JVM and the node watchers hold 5 to 10 GiB once warm, and backend, common, and REPL work needs none of it. `pdv stop --watchers` stops the frontend, Storybook, and exporter windows and keeps the backend. The cost is live frontend recompilation: an edit under `frontend/src` no longer reaches the browser on reload, because the UI then serves the precompiled bundle under `frontend/resources/public/js`. Keep the watchers while you iterate on the UI or show it to somebody.

The stop prints each pane's resident memory as it interrupts it, reports a window that was already idle, and sends a second interrupt halfway through the wait to a pane that ignores the first. It then judges the bundle from the host tree, and `pdv status` prints the same verdict on its `bundle:` line for every instance:

- **No bundle.** `main.js` is missing, so the page is blank.
- **A dev build.** A `cljs-runtime/` directory beside `main.js` marks the watcher's own output. It carries the shadow-cljs devtools client, which shows a red "Reconnecting..." overlay once the watcher is gone.
- **A stale release bundle.** A file under `frontend/src`, `frontend/resources/styles`, `frontend/translations`, or `common/src` is newer than `main.js`.
- **A current release bundle.** None of the above.

When the bundle is not current, the stop offers the release build on a terminal and builds nothing without one. `--build` builds without asking, even a current bundle, and `--no-build` never builds. Next, the stop makes sure the backend runs: an answer on its uREPL port 6062 means the JVM is up, a busy backend pane with the port still closed is a backend that is still starting and is left alone, and an idle pane gets `./scripts/start-dev`. The stop ends with the UI address and what it serves, the two ways to get a frontend change through (`pdv build-frontend`, or `pdv start --watchers`), the backend restart command, and the editor REPL command.

`pdv start --watchers` is the way back. It reports every pane that already runs something and leaves it alone, and it never sends an interrupt, so a misjudged pane costs at worst a command typed into a live watcher. When it started a watcher, it says that the first compile takes about 30 seconds, and that until it lands a reload shows the old bundle. That compile replaces a release bundle with a dev build, so the next `pdv stop --watchers` offers the build again.

### build-frontend makes the release bundle current

`pdv build-frontend` runs `./scripts/build app` in the container as `penpot`, which takes minutes. The build deletes `frontend/node_modules` and `frontend/resources/public` before it rebuilds them, and the `mcp` and `plugins` dependencies as well, so it never runs beside a frontend or Storybook watcher. On a terminal the verb offers to stop them and says when it does. Without a terminal, or when the offer is declined, it exits 3 and names `pdv stop --watchers --build`. A watcher that survives the stop also blocks the build. Afterwards it repairs two things the build breaks:

- **Write access.** The build recreates `resources/public` and `public/js` as the container user. Under rootless Docker the host user is `other` there, so the verb runs `chmod o+w` on both inside the container, as their owner.
- **config.js.** The build deleted it. The verb refreshes the instance's snapshot of `config.js` before the build and runs the tune's `config.js` step afterwards, which restores it (see the hygiene verbs below).

The verb ends with the UI address and what it serves. Hard-reload open tabs afterwards.

## The heap cap travels in `_JAVA_OPTIONS` because two scripts reset JAVA_OPTS

The default cap is `-Xmx768m -Xms50m`. pdv puts the cap in front of the `frontend`, `storybook`, `exporter`, and `backend` window commands, as both `_JAVA_OPTIONS` and `JAVA_OPTS`. Of those windows, the frontend, exporter, and backend start a Java Virtual Machine (JVM). The frontend window also carries the shadow-cljs process that compiles the storybook target.

The second variable is best effort. The image's `bashrc` exports `JAVA_OPTS` with a network flag and no `-Xmx`, and the backend's `scripts/_env` re-exports the same flags. A value passed in `JAVA_OPTS` alone therefore disappears before the JVM reads it. The JVM reads `_JAVA_OPTIONS` itself, after any script has run.

The cap reaches the window commands pdv sends, and not a release build or the test JVM. Release builds start with the JVM default heap. The test JVM starts with its own `-Xmx2g`.

`--java-opts` replaces the value, `DEVENV_JAVA_OPTS` sets the same value from the environment, and an explicitly empty value (`--java-opts ""`) removes the cap.

A seed profile can raise the backend's heap alone with `backend_heap: "2g"`, because hub files import into the backend JVM and 768 MiB is too little for some of them. The backend window then starts with `-Xmx2g -Xms50m`, and the other windows keep the default. `--java-opts` and `DEVENV_JAVA_OPTS` still win over the profile. pdv reads the value when it stages the profile and remembers it in the worktree's git directory as `pdv-heap`, so `pdv start --services backend` gives the backend the same heap. The key is left out of the profile's input hash, so changing it never rebuilds the database. A backend that was already running keeps its heap, and `pdv run` prints the restart command when that heap differs. `pdv seed` restarts the backend, so it applies the new heap itself.

## The admin-console is off, because no devenv runs one

The backend turns its admin-console (Nitrate) module on by default and calls the service at `PENPOT_ADMIN_CONSOLE_URI`, which nothing in the devenv answers. Every profile read then fails with "nitrate is unreachable". pdv starts the backend with `PENPOT_FLAGS="${PENPOT_FLAGS:-} disable-admin-console"` in front of `./scripts/start-dev`. `scripts/_env` appends its own flags after that value and never names the admin-console, and `scripts/_env.local` is sourced later, so `enable-admin-console` in that file turns the module back on for anyone who runs the service.

The frontend has the same flag. A frontend that carries penpot#13061 already turns it off in the devenv. For a branch cut before that change, a `config.js` that pdv generates also carries `disable-admin-console`. A `config.js` you wrote is left alone.

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

A container that cannot come up reports its state (`status`, `running`, `exit`, `error`) and the last 80 log lines. A tmux session that does not appear within 120 seconds prints the last 40 log lines. The same report appears in `pdv status` for an instance that is running but broken, which pdv measures by asking the container's health endpoint and by looking for the tmux session, and for a container that exited with any code other than 0 or 143. Exit 143 is the SIGTERM that `docker stop`, a daemon restart, or a host shutdown sends, so `pdv status` reports such a container as stopped, prints no log tail, and does not count it as a failure. No verb attaches to a session to show a failure, because the reader may not have a terminal that can host tmux.

A start waits for four things before it reports success: the container in the running state, a five-second settle after that, an answer from the health endpoint on port 8082, and the tmux session. The settle catches nginx dying just after Docker reports the container as running.

## pdv status names what has drifted since the container started

The mount source and the compose `working_dir` label are recorded when a container is created, so a worktree rename or a repointed slot symlink leaves both naming a path the bind left long ago. `pdv status` therefore asks the container for the device and inode it sees at `/home/penpot/penpot`, and matches them against the host paths the bind could have come from: the recorded source and its target, every workspace slot and its target, and every worktree of the checkout. It prints a warning with the recreate command when the recorded source no longer exists or now resolves to another tree, and a `serves:` line naming the tree the container really serves. A stale `working_dir` label gets a warning of its own, which is cosmetic, because the next `--recreate` rewrites it.

Inside the tmux session, every pane of a pdv window that runs nothing gets a warning with the `pdv start --services` command that revives it. An idle pane is either a deliberate `pdv stop` or a process that died, and in both cases the UI serves whatever bundle is on disk. The `bundle:` line says what that bundle is: none, a watcher's dev build, a stale release bundle with the newer source it found, or a current release bundle. A frontend window with no `frontend/resources/public/js/main.js` in the tree gets a warning that the UI is a blank page until the first compile lands.

## Two hygiene verbs prepare the tree and the container

`pdv acl` grants the container user write access to the bound tree. Rootless Docker maps the image's `penpot` user to a subordinate uid, which the host treats as `other` on a tree the host user owns, so every dependency install in the watcher windows fails with `EACCES`. pdv measures that uid with a one-shot container, grants it a read-write ACL and a default ACL on every entry the host user owns, and proves the grant by writing from inside a container. A rootful daemon maps the uid one to one, and the verb then reports that it has nothing to grant. `run` applies the grant before every start. A wsN slot that `manage.sh` fills with a copy does not exist before the first start, so grant the copy with `pdv acl --ws N` once it exists, or symlink a worktree into the slot beforehand.

`pdv tune` runs after every start and is safe to run again. Each step either checks or applies a fix that leaves running processes alone:

- **config.js.** The agentic frontend enables MCP only through `frontend/resources/public/js/config.js`, which is gitignored and which a frontend build deletes along with the rest of `resources/public`. While the file exists, the tune keeps a snapshot of it in the instance's home volume. Once the file is gone, or is a symlink the container cannot follow, the tune restores the snapshot. Without a snapshot, it writes `var penpotFlags = "disable-admin-console <flags>";`, where the flags come from `PDV_PENPOT_FLAGS` and default to `enable-mcp` for an agentic instance and to nothing otherwise. The last flag wins, so `PDV_PENPOT_FLAGS=enable-admin-console` turns the admin-console back on. `pdv run --agentic` does the same before the start, where `manage.sh` would refuse, in the tree the instance binds; a wsN slot that does not exist yet gets the file through ws0's checkout, which its first sync copies from. To retire the file for good, delete both the file and the snapshot, `~/.local/state/pdv/config.js` inside the instance.
- **clojure-lsp.** The `sv/defmethod` hook declares a var per RPC handler that only runtime dispatch resolves, so clojure-lsp reports every handler as an unused public var, and no clj-kondo setting reaches that linter. When the container home has no `~/.config/clojure-lsp/config.edn`, the tune installs `share/clojure-lsp-config.edn`, which turns the linter off. Serena reads the same file. A config you wrote yourself is left alone, with a warning when it keeps the linter on.
- **The skills link.** Claude Code reads skills only from `.claude/skills`, and the repository keeps them in `.agents/skills`. `manage.sh` creates the link in wsN copies only, so the tune creates `.claude/skills -> ../.agents/skills` in the bound tree when the path is free.
- **The tmux mouse.** The image ships `mouse off` and re-copies its `tmux.conf` on every start. With `PDV_TMUX_MOUSE=1`, the tune turns the mouse on in the running session.
- **Cargo home.** The image's `/opt/cargo` is owned by root, so a render-wasm build that must fetch a crate missing from the vendored set fails with `Permission denied`. The tune hands the directory to the container user.
- **Image currency.** The tune compares the running container's image with the local image and the local image with the registry, and prints the adoption command when either is stale.

## The development tools act on the instance that serves your worktree

`testjvm`, `eval`, `repl`, `lsp`, `jobs`, `build-frontend`, and `bug-report` work on a running instance. Without `--ws`, each one picks the running instance whose `/home/penpot/penpot` bind resolves to the git toplevel of the directory you call it from, so a session in a worktree reaches that worktree's instance with no flag. When no running instance serves that worktree, the verb lists every running instance with the tree it serves and exits 3. `bug-report` is the exception: it prints its checklist with placeholders instead. `--ws N` names an instance whatever the directory is. Every other verb keeps the ws0 default.

`testjvm` and `eval` print the choice on their first line, in the form `[pdv] instance: penpot-devenv-ws2-main  (worktree: <host path>)`.

### A persistent test JVM runs focused backend tests in under a second

A cold `clojure -M:dev:test --focus <id>` starts a JVM, resolves the classpath, and loads the whole backend on every run. `pdv testjvm start` keeps one JVM up inside the instance on the same classpath (`-M:dev:test` plus a `-Sdeps` alias that adds clj-reload and replaces `kaocha.runner` with pdv's `share/testjvm.clj`), with its nREPL on `127.0.0.1:6065` inside the container. `pdv testjvm run <id>…` reloads the namespaces whose files changed since the last run, plus the loaded namespaces that depend on them, and then runs kaocha with the repository's `tests.edn` and the ids `--focus` takes: a namespace, a var (`ns/test-name`), or a suite keyword (`:unit`). No id runs the whole suite. A focused run of `backend-tests.config-test` takes 0.8 seconds in a warm JVM.

```sh
pdv testjvm start                              # once per container
pdv testjvm run backend-tests.rpc-doc-test     # a namespace
pdv testjvm run backend-tests.rpc-doc-test/<test-name>   # one var
pdv testjvm run --seed 1912381049 <id>         # replay kaocha's random order
pdv testjvm cold --focus backend-tests.rpc-doc-test   # a fresh JVM, as CI runs it
```

The JVM never touches the running backend. It has its own process, its own nREPL port, its own log4j2 file under `/tmp/penpot-testjvm`, and the test database the container's `PENPOT_TEST_*` variables name. It starts with `-Xmx2g`, adds `enable-backend-asserts` to `PENPOT_FLAGS` as CI does (without it `app.config` compiles every `assert` out), dies with the container, and exits by itself after two hours without a call.

`run`, `reload`, and `cold` hold `/tmp/penpot-backend-test.lock` inside the container, one lock per instance, because every run on an instance shares its test database. A run waits for the lock within its `--timeout` (default 1800 seconds), and no test starts after the deadline. `start`, `stop`, and `restart` take a host lock per container, so parallel callers never start a second JVM. `stop` refuses while a run holds the JVM unless `--force`.

Restart the JVM after a change to `backend/deps.edn` or `common/deps.edn`, because the classpath is fixed at start, after an edit under `backend/dev` or to a namespace exempt from reload (`app.system`, `app.common.debug`, `user`), and after pdv's `share/testjvm.clj` changes. `run` and `reload` answer exit 5 and name the file in those cases. A reload that fails prints one line with the file, the line, and the cause, and the JVM stays usable.

| exit | `run` and `reload`                                                                     |
| ---- | -------------------------------------------------------------------------------------- |
| 0    | every test passed                                                                      |
| 1    | a test failed or errored, or no test matched the ids                                   |
| 2    | the reload failed and nothing ran                                                      |
| 3    | the JVM is down or died during the call, or no running instance serves the worktree    |
| 4    | the deadline passed, the wait for the lock timed out, or `cancel` stopped the run      |
| 5    | the JVM needs a restart (for `stop` and `restart`: a run holds the JVM)                |
| 6    | the storage is not writable by `penpot`, or the harness failed                         |
| 64   | bad usage                                                                              |

`cold` exits with kaocha's status. A build or a test run as the container's root leaves directories under `/tmp/penpot` and `backend/assets` that `penpot` cannot write, and `pdv testjvm repair` gives them back.

### eval runs Clojure in the test JVM or the running backend

`pdv eval` sends code over nREPL and prints output as the JVM prints it, then each top-level form's value. The default target is the test JVM, which reloads what changed first and is isolated from the running system, so it is the safe place to check a function or an assumption. `--target backend` reaches the running backend's nREPL on 6064, with `app.system/system` and the instance's database, and reloads nothing.

```sh
pdv eval '(+ 1 2)'                                  # the test JVM, after a reload
pdv eval - <<'EOF'                                  # quotes and newlines need no escaping
(require 'app.common.data)
(app.common.data/index-by :id [{:id 1}])
EOF
pdv eval --target backend --file backend/src/app/rpc/commands/files.clj   # hot-load an edited file
```

`--file` loads a host file with the nREPL `load-file` op, so errors cite its path and lines, and the container need not see the file. `eval` shares the exit table of `run`, except that 1 means the code threw and 4 means no answer within `--timeout` (default 120 seconds). Write fully qualified names, because an alias in `user` keeps pointing at the namespace object a reload replaced.

### repl bridges an editor to the backend

The host cannot reach the container's nREPL, because the devenv publishes no nREPL port. `pdv repl` makes the path. It starts a second nREPL server on 6066 inside the backend JVM with the cider-nrepl middleware, which Clojure 1.12's `add-lib` fetches into the running JVM, so the backend's dependencies stay untouched. It then writes `.nrepl-port` into the worktree and runs `lib/repl-bridge.py` in the foreground, which listens on host port `6064 + N × 10000` and pipes each connection through `docker exec`. The bridge needs `python3` on the host.

`CIDER_NREPL_VERSION` picks the cider-nrepl release, and an editor passes the one its CIDER expects. The first version loaded stays for the JVM's life, because `add-lib` skips a library already on the classpath, so restart the backend after a CIDER upgrade. A backend restart also takes the 6066 server down, and the next `pdv repl` brings it back. When cider-nrepl cannot start, the bridge serves the backend's plain nREPL. A new `pdv repl` on an instance replaces the bridge that already holds its port, and an editor that manages the bridge itself finds it by the pattern `repl-bridge.py .*--listen-port <port>`.

### lsp runs clojure-lsp inside the instance

An editor runs `pdv lsp` as its clojure-lsp binary, with no arguments or with `--ws N`. The verb starts `share/lsp-bridge.py` inside the container, which runs clojure-lsp as `penpot` with the container's classpath (`.m2`, `.gitlibs`) and rewrites every path between the host tree and `/home/penpot/penpot`. Stdout carries the protocol, so pdv prints its own messages on stderr. One editor session is one `docker exec` and one clojure-lsp, and both end when the editor closes the stream.

The image ships no clojure-lsp. pdv uses one on the container's `PATH`, else the binary Serena downloads into `~/.serena` in the home volume, which an agentic start provides. With neither, the verb exits 1 and says so.

### jobs reads the instance's job table

`pdv jobs [count]` prints the newest rows of the `job` table (webhook events, delete-object, garbage collection), 15 by default. A save that seems to vanish leaves a `process-webhook-event` row that reaches `completed` seconds later, and a failed job carries its error in the same row. The query runs against the database the live backend uses, else the worktree's database, and filters on the instance's `PENPOT_TENANT` (`devenv-wsN`).

### bug-report prints the checklist for whoever reports a devenv bug

`pdv bug-report` prints eight items to paste to the reporter: the code and the instance (`git status -sb`, `git rev-parse HEAD`, and `pdv status --ws N`), the exact steps, the visible error, the browser console with the websocket frames, the backend pane around the failure, the job table, the timestamp with its timezone, and the scope. Items 4, 5, and 6 usually settle a report on their own. A websocket-level frontend exception shows the failing frame, a backend exception shows the stacktrace, and the job table says whether the work arrived.

The checklist names the container, the tenant, and the `--ws` flag of the instance it resolved. The job-table item gives `pdv jobs --ws N` and, for a reporter without pdv, a plain `docker exec penpotdev-infra-postgres-1 psql` query against the database `pdv jobs` would read, which is the worktree's `pdvwt_<slug>` unless the live backend or a `--db` choice says otherwise. When no instance resolves, the verb still exits 0 and prints the template with placeholders, because a checklist is most needed when the instance is down. Every command in it runs in any Penpot checkout with pdv installed, and the git, docker, and psql lines need nothing else.

## The parity harness is the net every behaviour change lands behind

`test/parity.sh` has two modes. The offline mode reads the window plan out of the checkout's own `start-tmux.sh` and compares it with pdv's plan, then asserts the service rules, the cache policy, the heap cap, the seed naming rules, and the four bundle verdicts without touching a container. It also checks the development tools against a stub `docker`: bad usage exits with the documented status before any docker call, the caller's worktree selects the instance that binds it, the test JVM's staleness guard carries the hash of `share/testjvm.clj`, `bug-report` fills in the caller's instance and prints placeholders without one, and `status` names a repointed slot, a renamed tree, and a stale label. The live mode brings the same workspace up twice, with `pdv run` and with `./manage.sh run-devenv`, and compares the container state, the published ports, the mounts, and the tmux window set. A bare `pdv run` claims to be the upstream instance, so upstream is the reference. pdv runs first, because its ACL grant is what lets the upstream instance build on a rootless daemon. With `--fast`, the live mode also proves that `--recreate` keeps every named volume, that a JVM carries the cap in its environment, and that `status` reports a stopped instance.

The live mode runs in agentic mode by default, so pass `--plain` when `frontend/resources/public/js/config.js` is absent.

The live mode removes the instance's container before each recording. Run it against a workspace nobody is using, never against an instance you are working in.

pdv runs against a rootless or a rootful Docker daemon. `--rootful` points the run at `/var/run/docker.sock` through `DOCKER_HOST`, and the harness reports a skip when no rootful daemon exists. Rootful verification belongs to the upstream review, where reviewers run it on their own daemons. The chosen workspaces must be stopped on the rootless daemon first, because both daemons publish the same host ports.

## pdv deletes no volumes and builds no images

pdv never deletes a named volume. `--recreate` removes a container and leaves its volumes. `pdv stop` runs `manage.sh stop-devenv`, which removes the containers and keeps their volumes, and before that removes any target container that had already stopped. `pdv run --ws N` creates or syncs the wsN slot on first use, and no pdv verb deletes the slot.

The image is upstream's business. `./manage.sh pull-devenv` fetches it, `./manage.sh build-devenv` builds it locally, and `./manage.sh drop-devenv` removes it on a full teardown. A stale image shows up as a toolchain mismatch or a missing command inside the container, and the fix is a pull followed by a stop and a run.
