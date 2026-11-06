#!/usr/bin/env bash
# pdv-core.sh — repo discovery, the instance selector, manage.sh loading, and
# the docker/tmux helpers every pdv verb shares.
#
# Sourced by pdv, never executed. The caller sets PDV_SELF (the directory the
# pdv executable lives in) before sourcing.

set -euo pipefail

VERBOSE="${DEVENV_VERBOSE:-1}"   # 1: rationale (∵) + implications (⇒); 0: terse
DEST="/home/penpot/penpot"        # the bind mount every devenv carries
SESSION="penpot"                  # tmux session name start-tmux.sh and pdv share

say()  { printf '[pdv] %s\n' "$*"; }
vsay() { [ "$VERBOSE" = "1" ] && say "$@" || true; }
why()  { [ "$VERBOSE" = "1" ] && printf '  ∵ %s\n' "$*" || true; }
imp()  { [ "$VERBOSE" = "1" ] && printf '  ⇒ %s\n' "$*" || true; }
sub()  { printf '  %s\n' "$*"; }
warn() { printf '[pdv] WARNING: %s\n' "$*" >&2; }
die()  { printf '[pdv] %s\n' "$*" >&2; exit 1; }

svc_usage() { printf '[pdv] %s\n' "$*" >&2; exit 2; }

# Wrap a value in single quotes, escaping embedded quotes, for text that will
# be typed into a pane: the value can hold spaces and quotes and still arrive
# as one word.
shquote() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# --------------------------------------------------------------- the repo
# pdv acts on one Penpot checkout: the one it was told about, the one the
# caller stands in, or the estate default. ws0 binds whatever directory
# manage.sh runs from, so every verb runs with the cwd pinned to ROOT.
resolve_root() {
  local cand
  for cand in "${PDV_REPO:-}" "${PENPOT_REPO:-}" \
              "$(git rev-parse --show-toplevel 2>/dev/null || true)" \
              "$HOME/Code/penpot"; do
    [ -n "$cand" ] || continue
    if is_penpot_tree "$cand"; then
      ROOT=$(cd "$cand" && pwd)
      return 0
    fi
  done
  if [ -n "${PDV_REPO:-}${PENPOT_REPO:-}" ]; then
    die "not a Penpot checkout: ${PDV_REPO:-$PENPOT_REPO} (needs manage.sh and docker/devenv/docker-compose.main.yml)"
  fi
  die "no Penpot checkout found: run pdv from one, pass --repo PATH, or export PENPOT_REPO"
}

is_penpot_tree() {
  [ -x "$1/manage.sh" ] && [ -f "$1/docker/devenv/docker-compose.main.yml" ]
}

# ------------------------------------------------------------- --ws, anywhere
# A `--ws N` pair anywhere selects the instance, is consumed for pdv's own
# verbs, and stays in REST for a manage.sh fall-through.
# The ceiling is read from manage.sh so the two cannot drift.
parse_instance() {
  local a prev="" value=""
  WS_GIVEN=false
  REST=()
  for a in "$@"; do
    if [ "$prev" = "--ws" ]; then
      value="$a"; WS_GIVEN=true
      prev=""
      continue
    fi
    if [ "$a" = "--ws" ]; then prev="--ws"; continue; fi
    REST+=("$a")
  done
  if [ "$prev" = "--ws" ]; then svc_usage "--ws needs a value"; fi

  local max
  max=$(sed -n 's/^PENPOT_MAX_WS_INDEX=\([0-9][0-9]*\).*/\1/p' "$ROOT/manage.sh" | head -1)
  max="${max:-5}"
  if $WS_GIVEN; then
    case "$value" in
      ''|*[!0-9]*)
        die "invalid --ws value '$value': expected an integer in 0..$max" ;;
    esac
    if [ "$value" -gt "$max" ]; then
      die "invalid --ws value '$value': manage.sh caps workspaces at $max (higher indexes overflow the 16-bit TCP port range)"
    fi
    WS_INDEX="$value"
  else
    WS_INDEX=0
  fi
  WS="ws${WS_INDEX}"
  CTR="penpot-devenv-${WS}-main"
}

# ---------------------------------------------------------- manage.sh, loaded
# pdv never restates compose environment: it loads manage.sh's own functions
# and calls instance-compose, so ports, names, volumes and the network stay
# whatever the checkout says. The preamble is run here, not forked, so
# dynamic-scope options like devenv_gpu reach instance-compose.
manage_load() {
  [ -z "${PDV_MANAGE_LOADED:-}" ] || return 0
  export PENPOT_WORKSPACES_DIR="${PENPOT_WORKSPACES_DIR:-$(workspaces_dir)}"
  # manage.sh appends safe.directory to the global git config on every run;
  # hand it a snapshot so pdv does not grow that file.
  if [ -z "${GIT_CONFIG_GLOBAL:-}" ] || [ ! -f "$GIT_CONFIG_GLOBAL" ]; then
    GIT_CONFIG_GLOBAL=$(mktemp "${TMPDIR:-/tmp}/pdv-gitconfig.XXXXXX")
    if [ -f "$HOME/.config/git/config" ]; then cp "$HOME/.config/git/config" "$GIT_CONFIG_GLOBAL"; fi
  fi
  export GIT_CONFIG_GLOBAL
  # Source in this shell (a subshell would lose the functions), from ROOT
  # (defaults.env and the compose files resolve against it), with a harmless
  # subcommand so the dispatcher at the end of manage.sh only prints usage.
  local -a saved=("$@")
  cd "$ROOT"
  set -- help
  # Stdout goes to /dev/null because the dispatcher prints usage; stderr stays
  # live so manage.sh's own complaint (an unreadable defaults.env, say) reaches
  # the reader before it exits.
  source ./manage.sh >/dev/null || true
  set -- ${saved[@]+"${saved[@]}"}
  command -v instance-compose >/dev/null || die "could not load manage.sh functions from $ROOT"
  PDV_MANAGE_LOADED=1
}

# Where the wsN slots live: manage.sh's own default, with the overlay
# dispatcher's XDG fallback for a checkout whose manage.sh predates it.
workspaces_dir() {
  if [ -d "$HOME/.penpot/penpot_workspaces" ]; then
    printf '%s' "$HOME/.penpot/penpot_workspaces"
  else
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/penpot-devenv/workspaces"
  fi
}

# ---------------------------------------------------------------- containers
mount_src() {
  docker inspect -f \
    '{{range .Mounts}}{{if eq .Destination "'"$DEST"'"}}{{.Source}}{{end}}{{end}}' \
    "$1" 2>/dev/null || true
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

main_container() {
  local name
  name=$(devenv-main-container "$WS" 2>/dev/null || true)
  printf '%s' "${name:-$CTR}"
}

# The instance's own view of itself: state, ports, tree, window set.
container_state() {
  docker inspect -f 'status={{.State.Status}} running={{.State.Running}} exit={{.State.ExitCode}} error={{.State.Error}}' \
    "$1" 2>/dev/null || true
}

published_ports() {
  docker port "$1" 2>/dev/null | sort || true
}

# --------------------------------------------------------------- failure report
# What the container is, then the tail that explains it. No attach, because
# the person reading it is not in the tmux session and the session may not even
# exist.
print_main_failure() {
  local ctr="$1" reason="${2:-main container is not running}" state
  state=$(container_state "$ctr")
  echo "[pdv] $reason: ${state:-container not found}" >&2
  if container_exists "$ctr"; then
    echo "[pdv] last $ctr logs:" >&2
    docker logs --tail 80 "$ctr" >&2 || true
  fi
}

# The signature: compose reuses a container whose network is gone, and nginx
# dies on its first DNS lookup. The escape hatch is `--recreate`.
stale_network_signature() {
  container_exists "$1" || return 1
  docker logs --tail 200 "$1" 2>&1 | grep -q 'host not found in upstream'
}

report_stale_network() {
  local ctr="$1" idx="${2:-$WS_INDEX}"
  cat >&2 <<EOF
[pdv] $ctr carries the stale-network signature: nginx died on
  [emerg] host not found in upstream "raw.githubusercontent.com"
That happens when the container is left attached to a docker network that no
longer exists (a drop-devenv, a docker daemon restart, another stack churning
the network). compose reuses the container by name, so a plain start keeps
re-launching the same networkless zombie.
[pdv] escape hatch: pdv run --ws $idx --recreate   (removes the container, keeps every volume)
EOF
}

# -------------------------------------------------------------------- tmux
tmx() { docker exec "$CTR" sudo -EH -u penpot tmux "$@"; }

# Run a shell command as the container user, with the image's HOME and env.
as_penpot() { docker exec -i "$CTR" sudo -EH -u penpot bash -c "$1"; }

has_session() {
  tmx has-session -t "$SESSION" 2>/dev/null
}

# A pane is "busy" iff its first process was exec-replaced by another program,
# or is still a shell but has children. tmux's pane_current_command cannot tell
# them apart: watch scripts are bash wrappers, so the group leader is named
# bash and a live watcher would read as an idle shell. devenv-slim, devenv-fatten
# and pdv share this definition, so a pane one calls stopped is stopped for all.
pane_busy() {
  docker exec "$CTR" bash -c '
    comm=$(ps -o comm= -p "$1" 2>/dev/null)
    [ -n "$comm" ] || exit 1
    case "$comm" in
      bash|sh|zsh|dash|fish)
        kid=$(ps --ppid "$1" -o cmd= 2>/dev/null | head -1)
        if [ -n "$kid" ]; then echo "$kid"; exit 0; else exit 1; fi ;;
      *) echo "$comm"; exit 0 ;;
    esac' _ "$1"
}

pane_tree_rss_mb() {
  docker exec "$CTR" ps -e -o pid=,ppid=,rss= 2>/dev/null | awk -v root="$1" '
    { pp[$1]=$2; r[$1]=$3 }
    END { for (p in pp) { q=p; while (q!=root && q!=1 && (q in pp)) q=pp[q];
                          if (q==root) t+=r[p] }
          if (t) printf("%d", t/1024); else print "?" }'
}

# Everything a wsN (N≥1) instance needs that ws0 gets for free, printed rather
# than done: which worktree the slot points at is the caller's choice, and so
# is which instance an agent session talks to.
ws_briefing() {
  local dir="$PENPOT_WORKSPACES_DIR/$WS"
  say "workspace $WS: $dir"
  if [ -L "$dir" ]; then
    why "symlink to $(readlink -f "$dir") — run binds that tree, so commits land in the worktree you meant"
  elif [ -d "$dir" ]; then
    why "a real directory, so it is an rsync clone on branch $WS/<branch>, not your worktree"
    imp "to bind a worktree instead: pdv stop --ws $WS_INDEX; rm -rf '$dir'; ln -s ~/Worktrees/<repo>-<branch> '$dir'; then run again"
  else
    say "workspace $WS does not exist yet"
    imp "bind a worktree before the first run: ln -s ~/Worktrees/<repo>-<branch> '$dir'"
  fi
  say "agent MCP for $WS: PENPOT_MCP_PORT=$(( 4401 + WS_INDEX * 10000 )) SERENA_MCP_PORT=$(( 14181 + WS_INDEX * 10000 ))"
  why ".mcp.json reads those two variables and falls back to ws0's ports, so a session started without them talks to ws0 whatever worktree it sits in"
}

# ------------------------------------------------------------ overlay scripts
# The capability helpers a checkout installs beside manage.sh, reached through
# the tree. A checkout without them reports the missing verb instead of
# guessing.
overlay_script() {
  local name="$1"
  [ -x "$ROOT/.devenv/$name" ] || die "$ROOT carries no $name helper, so the '$name' capability is not installed"
  printf '%s' "$ROOT/.devenv/$name"
}

run_overlay() {
  local name="$1"; shift
  local script
  script=$(overlay_script "$name")
  PENPOT_MAIN_CONTAINER_NAME="$CTR" exec "$script" "$@"
}
