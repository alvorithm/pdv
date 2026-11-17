---
genre: guide
---

# An agent sets pdv up for someone else

This is the procedure an agent follows on a developer's machine, and the procedure an agent inside the Penpot devenv container hands over step by step. It assumes a shell, `git`, and a person who can supply the machine's root password. Each step says where it runs, gives the command, names the output that means success, and lists the failures worth expecting with the fix for each.

Two rules govern the whole procedure.

- Every `pdv` command and every `./manage.sh` command runs on the host, as the developer's own user. pdv drives the host's Docker CLI and daemon, and the devenv container carries neither.
- A command that needs root goes to the developer in one fenced block, verbatim. Wait for the result before the next step, and never run `sudo` yourself.

## 0. Find out where you run

Runs anywhere: the host, or the container.

```sh
[ -f /.dockerenv ] && echo container || echo host
whoami
command -v docker || echo "no docker CLI"
[ -f /home/penpot/penpot/manage.sh ] && echo "bound tree at /home/penpot/penpot"
```

A host prints `host`, prints the developer's own login name, prints a path for `docker`, and prints nothing on the last line. The devenv container prints `container`, prints `penpot`, finds no `docker` CLI, and finds the bound tree.

A host agent runs every step below directly. A container agent runs step 0 and step 7, and hands the rest to the developer one fenced block at a time. From inside the container you can still verify the backend and the agent account: nginx answers on `https://localhost:3449` whatever the instance number is, and the bound tree is at `/home/penpot/penpot`.

## 1. Check the prerequisites

Runs on the host.

```sh
for c in bash git curl docker setfacl readlink sha256sum; do
  printf '%-9s %s\n' "$c" "$(command -v "$c" || echo MISSING)"
done
printf 'bash %s\n' "${BASH_VERSINFO[0]}"
docker info -f '{{.ServerVersion}}' >/dev/null && echo "daemon reachable"
```

Success: a path for `bash`, `git`, `curl`, `docker`, `readlink`, and `sha256sum`, a bash major version of 4 or more, and `daemon reachable`. `setfacl` may print `MISSING` here, because only a rootless host needs it and step 2 settles which host this is.

A `MISSING` line, or bash 3, is a package to install. Each command below needs root, so hand the one matching the machine to the developer and wait for the answer.

| family          | command                                               |
| --------------- | ----------------------------------------------------- |
| Debian, Ubuntu  | `sudo apt-get install -y bash coreutils curl git acl` |
| Fedora, RHEL    | `sudo dnf install -y bash coreutils curl git acl`     |
| Arch            | `sudo pacman -S --needed bash coreutils curl git acl` |
| macOS, Homebrew | `brew install bash coreutils curl git`                |

Docker is not in that table because the daemon and its privileges are Docker's own install. Point the developer at <https://docs.docker.com/engine/install/> for a rootful daemon, or at <https://docs.docker.com/engine/security/rootless/> for a rootless one, which also needs the `uidmap` package and unprivileged user namespaces. Adding the developer to the `docker` group takes effect in a new login session, so `daemon reachable` can still fail in the shell that added them.

macOS is the exception in that table. pdv reads `readlink -f`, `stat -c`, and `sha256sum`, which are GNU tools, so `$(brew --prefix coreutils)/libexec/gnubin` must sit before `/bin` in `PATH`. macOS ships bash 3.2 as `/bin/bash`, so the Homebrew bash is the one to use. Docker Desktop starts a rootful daemon inside a virtual machine, so step 2 lands on rootful. `brew install acl` supplies `setfacl` and `getfacl`, and whether the grant verifies depends on the file sharing Docker Desktop uses, so read the result of `pdv acl` rather than assuming it.

## 2. Decide rootless or rootful

Runs on the host.

```sh
docker info -f '{{.SecurityOptions}}'
printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST:-unset}"
docker context show
```

Either line is success: one contains `name=rootless`, the other does not. Both are supported, and the differences below are all that follow from the choice.

|                            | rootless                                                                              | rootful                                                 |
| -------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| the tree's ownership       | the container's `penpot` user is a subordinate uid, so the tree needs an ACL          | uids map one to one, so ownership already allows writes |
| `pdv acl`                  | measures the container uid, grants the ACL, and proves it by writing from a container | prints `acl: nothing to grant`                          |
| the daemon the CLI reaches | usually `unix:///run/user/<uid>/docker.sock` through the docker context               | `/var/run/docker.sock`                                  |
| published ports            | the same host ports, and none below 1024                                              | the same host ports                                     |

pdv sets no `DOCKER_HOST` of its own. It calls the `docker` the shell resolves, so the context or the variable decides which daemon it acts on, and `pdv status` prints the daemon it looked at when it finds no containers. Both daemons publish the same host ports, so stop an instance on one before starting the same instance on the other.

## 3. Install pdv

Runs on the host.

```sh
mkdir -p ~/Code ~/.local/bin
git clone https://github.com/alvorithm/pdv.git ~/Code/pdv
ln -s ~/Code/pdv/pdv ~/.local/bin/pdv
pdv help
```

Success: `pdv help` prints the usage block and exits 0. That block is the surface this guide drives, so read it once.

Failure: `ln: failed to create symbolic link` with `File exists` means an older link is there, and `ln -sf ~/Code/pdv/pdv ~/.local/bin/pdv` replaces it. `pdv: command not found` after a successful link means the directory is not on `PATH`:

```sh
case ":$PATH:" in *":$HOME/.local/bin:"*) echo "on PATH" ;; *) echo "not on PATH" ;; esac
```

With `not on PATH`, run the command by its path, `~/Code/pdv/pdv run --services frontend,backend`, and ask the developer to add `export PATH="$HOME/.local/bin:$PATH"` to their shell profile. The clone over `https` needs no key, and a `git@github.com:` clone of a public repository fails without one.

## 4. Get a Penpot checkout and its image

Runs on the host.

```sh
git clone https://github.com/penpot/penpot.git ~/Code/penpot
mkdir -p ~/Worktrees
git -C ~/Code/penpot worktree add ~/Worktrees/penpot-feature -b my-branch origin/develop
cd ~/Worktrees/penpot-feature
pdv pull-devenv
```

Success: `pdv pull-devenv` finishes, and `docker image ls penpotapp/devenv` lists a tag. That verb is `./manage.sh pull-devenv` unchanged, because pdv runs any verb it does not own through the checkout's `manage.sh`. pdv loads that same `manage.sh`, so the checkout must carry `manage.sh` and `docker/devenv/defaults.env`.

pdv acts on the worktree you call it from. From `~/Worktrees/penpot-feature` it acts on that worktree as instance ws0. `--repo PATH` and `PENPOT_REPO` name another checkout, and `~/Code/penpot` is the fallback when neither is given and the current directory is not a checkout.

A second worktree at the same time wants its own instance. `pdv run --ws 2` acts on `$PENPOT_WORKSPACES_DIR/ws2`, which defaults to `~/.local/share/penpot-devenv/workspaces/ws2` and wants a symlink to the worktree:

```sh
mkdir -p ~/.local/share/penpot-devenv/workspaces
ln -s ~/Worktrees/penpot-other ~/.local/share/penpot-devenv/workspaces/ws2
```

A real directory in that slot makes `manage.sh` rsync a copy, and commits made in the copy have to be fetched back.

Failure: `manage.sh: cannot read docker/devenv/defaults.env` means the directory is not a Penpot checkout. `permission denied while trying to connect to the Docker daemon socket` means the developer is not in the `docker` group in this session, or the rootless socket is not running.

## 5. Bring an instance up

Runs on the host.

```sh
cd ~/Worktrees/penpot-feature
pdv run --services frontend,backend
pdv status
```

Success: `pdv run` prints `instance ws0 ready`, then the UI at `https://localhost:3449` and `http://localhost:3450`, then the attach and status hints. `pdv status` prints `instance ws0 (penpot-devenv-ws0-main)` with `state: running`, the published `ports:`, the `tree:` it binds, its `branch:`, a `seed:` line naming the profile and database, and the `windows:` list. The expected window set for this command is `frontend watch` and `backend`.

The first run is the slow one. It pulls the image when it is absent, grants the ACL, brings up the shared infrastructure, creates the worktree's database, and the frontend's first start builds the Rust/WASM renderer. Later starts keep the compile caches, and only `--clean` rebuilds them. Running the same command on an instance that is already up tunes it and starts the windows that are missing or stopped, so a second run is safe. `pdv attach` opens tmux in the instance and `pdv stop` stops it.

Failure: pdv reports in place rather than attaching, so read the report before changing anything. A failed start prints the container's state and the last 80 log lines. A tmux session that does not appear within 120 seconds prints the last 40. `pdv status --ws 0` prints the same report for an instance that is running but broken, and `pdv logs` follows the container log. The failures worth expecting at this step are `port is already allocated`, `EACCES` in a watcher pane, a log ending with `host not found in upstream`, and `seed: profile '<name>' is not in <PDV_FIXTURES>/profiles`. Step 9 carries each one.

## 6. Seed the database from fixtures

Runs on the host.

A profile is a YAML file in the fixture repository. That repository is private, so its owner adds the developer as a collaborator first.

```sh
git clone git@github.com:alvorithm/penpot-fixtures.git ~/Code/penpot-fixtures
ls ~/Code/penpot-fixtures/profiles
```

Success: the `ls` lists `profiles/<name>.yaml` files. `~/Code/penpot-fixtures` is pdv's default, so no variable is needed when the clone lands there. A clone elsewhere needs `PDV_FIXTURES` pointing at it, as in `export PDV_FIXTURES=~/src/penpot-fixtures`.

Failure: `Permission denied (publickey)`, or a 404 over `https`, means no access yet. Ask the repository's owner for collaborator access. Without the repository the procedure continues: pdv's built-in profile creates `odysseus@penpot.app` and `hermes@penpot.app` in an `Ithaca` team, imports nothing, and still writes the agent file in step 7.

Then seed:

```sh
cd ~/Worktrees/penpot-feature
pdv run --seed branching --services frontend,backend
pdv seed status
```

Success: `pdv run` prints `seed: staging the profile 'branching' for pdvwt_<slug> (bucket pdvwt-<slug>)` before the container starts, then `seed: applied the profile` and `seed: wrote <tree>/.pdv-agent.json (mode 600)` once the backend answers. `pdv seed status` prints `seed status: ws0, database pdvwt_<slug>, bucket pdvwt-<slug>` and then `profile:`, `worktree:`, `hash:`, `seeded at:`, `schema head:`, and one `files:` line per imported source.

Every shipped profile seeds named accounts from the same cast, and every account's password is `123123`. A human logs in at `https://localhost:3449` as the owner, `odysseus@penpot.app`, with `123123`. The agent account is `hermes@penpot.app`, and step 7 reads its token from `.pdv-agent.json`.

The database name follows the worktree directory: `penpot-iop-vc-preview` becomes `pdvwt_penpot_iop_vc_preview`, with the bucket `pdvwt-penpot-iop-vc-preview`. A second run with the same profile imports nothing, because the input hash matches. A changed profile rebuilds the database before the backend starts, because an import always assigns new file ids.

The name is remembered per worktree. `PDV_SEED_DEFAULT=branching pdv run` seeds that profile in every worktree that chose none, and `pdv run --seed none` forgets the choice and keeps the built-in users.

Failure: a profile name that does not exist stops the run before any window starts, with `seed: profile '<name>' is not in <PDV_FIXTURES>/profiles`. Fix the name or the clone path, never the database. `seed: the instance is up but not seeded` means the backend did not answer in time, and `pdv seed` retries the whole post-start half. A seed needs a backend window, so `pdv run --services frontend` reports `seed: no backend window selected, so nothing was seeded`. `seed status: the shared postgres is not running` means no instance is up, and `seed status: <db> does not exist yet` means this worktree's database has not been created.

Name what you create so the next reader can find it without asking you. A project you make while working is `<YYYYMMDD> <Area>: <what it shows>`, for example `20261117 Tokens: a set applied to a component's copies`. Rename every file in it to say what it demonstrates before you export, never "Untitled" or "copy 2". The fixture repository's README carries the full scheme.

Export before the worktree goes away:

```sh
pdv bundle save bundles/tokens/20261117-set-applied-to-copies.penpot \
  --project "20261117 Tokens: a set applied to a component's copies"
```

Success: the project is written under the fixture repository, and the command prints the `git add` and `git commit` lines. It never commits. A path without a date prints a naming warning, and so does a profile project outside the pattern when the driver stages it. Fix the name rather than ignore the line.

What is not exported disappears. The database and the bucket live as long as the worktree path exists, and pdv sweeps the `pdvwt_*` databases whose recorded path is gone at the next `pdv run` and before `pdv stop --all`. `pdv stop` keeps them. `--db penpot` is the escape to the legacy shared database, which pdv never creates, seeds, drops, or sweeps.

## 7. Use the agent account from inside the container

Runs in the container. This is the step a container agent completes alone.

```sh
ls -l /home/penpot/penpot/.pdv-agent.json
TOKEN=$(sed -E 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' /home/penpot/penpot/.pdv-agent.json)
curl -ks -H "Authorization: Token $TOKEN" https://localhost:3449/api/rpc/command/get-teams
```

Success: the file exists with mode `-rw-------`, and the RPC answers with a JSON array of teams, `[]` included for an account that belongs to none. The file holds four keys: `url`, `email`, `token`, and `database`, and `email` names `hermes@penpot.app` in every shipped profile.

The token is a credential. Never print it, never pass it on a command line that the shell history keeps, and never commit it. pdv keeps the file out of `git status` by adding `/.pdv-agent.json` to the repository's `<git-common-dir>/info/exclude`.

The port is always 3449 inside the container, because that is the container's own nginx. The `url` field carries the host-facing URL, which differs on a second instance: `https://localhost:13449` on ws1. Call the URL from the file when you are on the host, and `https://localhost:3449` when you are in the container.

`get-profile` is the second check, and it prints the `fullname` and `id` behind the token, `Hermes` for the agent every shipped profile seeds:

```sh
curl -ks -H "Authorization: Token $TOKEN" https://localhost:3449/api/rpc/command/get-profile
```

Failure: `No such file or directory` means the seed has not run, or the profile marks no user with `agent: true`. Run `pdv seed --ws N` on the host. An error object instead of a team list means the token is stale or the database was rebuilt, so seed again and re-read the file.

## 8. Agentic mode for a harness outside the container

Runs on the host. A harness inside the container edits the bound tree directly and does not need this step.

```sh
cd ~/Worktrees/penpot-feature
pdv run --agentic --services frontend,backend,mcp
./manage.sh start-coding-agent claude
```

Success: `pdv run` adds an `mcp` window to the plan and prints the usual ready block. It writes `frontend/resources/public/js/config.js` when the file is absent, because the frontend enables MCP only through that file, and it writes the MCP client configurations through `manage.sh`: `.devenv/mcp/claude-code.json`, `.devenv/mcp/opencode.json`, and `.vscode/mcp.json`. `start-coding-agent` then starts the client with the matching configuration and no error.

The ports are the instance's own: the MCP server answers on `4401 + N × 10000` and Serena on `14181 + N × 10000`, so ws0 uses 4401 and 14181, and ws2 uses 24401 and 34181. Naming `mcp` or `serena` in `--services` turns agentic mode on by itself, and `--agentic` with no `--services` gives every window.

Failure: `start-coding-agent: instance 'ws0' is not running` means the instance is down. `start-coding-agent: '<client>' is not on PATH` means the client binary is missing. `start-coding-agent: ... .devenv/mcp/claude-code.json not found` means the agentic run did not write the configurations, which happens when `.devenv/shared` or `.devenv/templates` is missing from the checkout. The merge step calls `python3`, so a host without it fails here. `--opencode-config-dir DIR` mounts a personal opencode configuration, and `--serena-context CTX` changes Serena's context.

## 9. Troubleshooting

| symptom                                                                                                           | what it means                                                                                                      | fix                                                                                                |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| the main container is `Exited (1)` and its log ends with `host not found in upstream "raw.githubusercontent.com"` | the container is attached to a Docker network that no longer exists                                                | `pdv run --recreate` removes the container and keeps every volume                                  |
| `port is already allocated`                                                                                       | another stack holds the host port                                                                                  | `docker ps --format '{{.Names}} {{.Ports}}' \| grep <port>` names the holder, then stop that stack |
| `EACCES` in the watch panes, or `pnpm install` failing there                                                      | the container user cannot write the tree                                                                           | `pdv acl`, then `pdv start --watchers` to restart the failed panes, never the container            |
| a watcher pane is idle after a restart                                                                            | the window's command is not running                                                                                | `pdv start --watchers`, which installs missing node dependencies first                             |
| the backend dies with an out-of-memory error                                                                      | the heap cap is too small for the branch                                                                           | `pdv run --java-opts "-Xmx1500m -Xms50m"`                                                          |
| the UI shows old code after a restart                                                                             | the compile cache is stale                                                                                         | wait for the first compile, or `pdv run --clean`                                                   |
| every profile read fails with `nitrate is unreachable`                                                            | the backend lost `disable-admin-console`, usually because `backend/scripts/_env.local` sets `enable-admin-console` | remove the flag from that file and restart the backend window with `pdv run --services backend`    |
| `pdv seed` reports `the backend of <container> is on the database <x>, not <y>`                                   | the backend was started outside its window, or the worktree's remembered database changed                          | `pdv seed --ws N` rebuilds the database and restarts the backend on it                             |
| a worktree's database has no fixtures                                                                             | the profile never applied, or the worktree uses the built-in profile                                               | `pdv seed --ws N`, then `pdv seed status`                                                          |
| `.pdv-agent.json` is missing after a run                                                                          | no seed ran, or the profile marks no agent user                                                                    | `pdv seed --ws N`, and check the profile's `agent: true`                                           |
| the tmux session does not appear within 120 seconds                                                               | the container is up but its windows are not                                                                        | read the last 40 log lines pdv printed, then `pdv logs`                                            |
| `pdv status` lists no containers                                                                                  | the shell's `docker` points at a daemon that holds no Penpot instance                                              | compare `docker context show` and `DOCKER_HOST` with step 2                                        |

## Where the detail lives

- `pdv help` lists every verb and flag, and the environment variables.
- The manual explains the model behind each step: [instances and the ws slot](manual-pdv.md#an-instance-is-wsn-and-ws0-binds-the-checkout-pdv-runs-against), [services](manual-pdv.md#a-service-is-a-window-and-storybook-also-names-a-compile-target), [the per-worktree database](manual-pdv.md#each-worktree-gets-its-own-database-and-bucket), [the profile schema](manual-pdv.md#a-profile-is-what-goes-into-the-database), [the database's lifetime](manual-pdv.md#the-database-lives-as-long-as-its-worktree), [the ACL grant and the tune](manual-pdv.md#two-hygiene-verbs-prepare-the-tree-and-the-container), [the admin-console](manual-pdv.md#the-admin-console-is-off-because-no-devenv-runs-one), [the heap cap](manual-pdv.md#the-heap-cap-travels-in-_java_options-because-two-scripts-reset-java_opts), [the cache policy](manual-pdv.md#a-watcher-restart-keeps-the-caches-and---clean-answers-a-toolchain-change), [the recreate path](manual-pdv.md#a-container-on-a-dead-network-is-the-zombie-that---recreate-removes), and [failure reporting](manual-pdv.md#failures-are-reported-in-place-never-through-an-attach).
- `README.md` is the short form of the same surface.
