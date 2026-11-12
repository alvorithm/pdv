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
# bash and a live watcher would read as an idle shell. Every verb that stops
# or starts a window uses this definition.
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
    imp "to bind a worktree instead: pdv stop --ws $WS_INDEX; rm -rf '$dir'; ln -s <worktree> '$dir'; then run again"
  else
    say "workspace $WS does not exist yet"
    imp "bind a worktree before the first run: ln -s <worktree> '$dir'"
  fi
  say "agent MCP for $WS: PENPOT_MCP_PORT=$(( 4401 + WS_INDEX * 10000 )) SERENA_MCP_PORT=$(( 14181 + WS_INDEX * 10000 ))"
  why "a coding agent reaches this instance's MCP servers when started with './manage.sh start-coding-agent <client> --ws $WS_INDEX', which wires those ports"
}

# ------------------------------------------------------------------ the acl
# Rootless Docker maps the image's `penpot` user to a subuid, which falls into
# `other` on a tree the host user owns, so every `pnpm install` in the watch
# panes fails with EACCES and nothing is built. A worktree does not inherit
# the main checkout's ACL, so each tree is granted once, before the container
# starts: the watchers begin their installs within seconds of it.
#
# The container uid is measured (a one-shot container creates a file, the host
# stats it) rather than computed from /etc/subuid. The grant, on every entry
# the host user owns:
#   user:<cuid>:rwX           the container user reads and writes
#   default:user:<cuid>:rwx   and so does everything created later
#   default:user:<me>:rwx     the host user keeps write access to what the
#                             container creates: a directory with a default
#                             ACL ignores the umask, and the inherited
#                             default:other::r-x would lock the host user out
# Symlinks are never followed. Entries the container already owns are skipped:
# only their owner may change their ACL, and the container can write them.
#
# A missing tree is a wsN slot that manage.sh is about to fill with a copy.
# Nothing is granted then: rsync -a and install -D set the ACL mask from their
# own modes, so a default ACL on the parent would be masked to r-x where the
# watcher writes its build. `pdv acl --ws N` grants the copy once it exists.
grant_acl() {
  local tree="$1" img="$DEVENV_IMGNAME:$DEVENV_TAG" probe cuid me acl
  if [ ! -d "$tree" ]; then
    vsay "acl: skipped, $tree does not exist yet"
    imp "symlink a worktree into the slot before the first run, and the grant applies to that worktree; a copy made by manage.sh is granted by 'pdv acl --ws $WS_INDEX' once it exists"
    return 0
  fi
  tree=$(readlink -f "$tree")
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    vsay "acl: skipped, image $img is not present yet, so the container uid cannot be measured"
    imp "run pulls it; run 'pdv acl' afterwards if the watch panes fail with EACCES"
    return 0
  fi

  # The probe directory must be writable by a uid the host user cannot name
  # yet, hence 777; it lives for the duration of one docker run.
  probe=$(mktemp -d)
  chmod 777 "$probe"
  if ! docker run --rm --network none --user penpot --entrypoint touch \
         -v "$probe:/probe" "$img" /probe/uid >/dev/null; then
    rm -rf "$probe"
    warn "acl: the probe container could not run, so the container uid is unknown"
    return 1
  fi
  cuid=$(stat -c %u "$probe/uid")
  rm -rf "$probe"
  me=$(id -u)

  if [ "$cuid" = "$me" ]; then
    vsay "acl: nothing to grant, the container user penpot is host uid $me, the owner of $tree"
    why "Docker maps uids one to one here (rootful, no user-namespace remap), so ownership already gives write access"
    return 0
  fi

  command -v setfacl >/dev/null || { warn "acl: setfacl is missing (install the acl package); the container user (host uid $cuid) cannot write $tree"; return 1; }
  acl=$(getfacl -cpn "$tree" 2>/dev/null || true)
  if grep -q "^user:$cuid:rwx" <<<"$acl" && grep -q "^default:user:$cuid:rwx" <<<"$acl"; then
    vsay "acl: already granted, $tree carries user:$cuid:rwx and its default (container user penpot = host uid $cuid)"
    return 0
  fi

  say "acl: granting host uid $cuid (container user penpot) write access to $tree"
  find "$tree" -user "$me" ! -type l -exec setfacl -m "u:$cuid:rwX" {} +
  find "$tree" -user "$me" -type d -exec setfacl -m "d:u:$cuid:rwx,d:u:$me:rwx" {} +

  if docker run --rm --network none --user penpot --entrypoint sh \
       -v "$tree:/w" "$img" -c \
       'd=/w/frontend; [ -d "$d" ] || d=/w; touch "$d/.pdv-acl-probe" && rm "$d/.pdv-acl-probe"'; then
    say "acl: verified, penpot creates and removes a file in the tree from inside a container"
  else
    warn "acl: penpot still cannot write $tree after the grant; inspect with getfacl -n $tree"
    return 1
  fi
  imp "an instance already running on this tree started its panes before the grant: restart the failed panes (pdv start --watchers), never the container"
}

# ----------------------------------------------------------------- the tune
# Idempotent post-start fixes for a running instance. Each step either checks
# or applies a fix that never changes what is running.

# The instance's own state directory, inside its home volume: it survives a
# container recreate and belongs to that one instance.
CTR_STATE="/home/penpot/.local/state/pdv"
CONFIG_JS="frontend/resources/public/js/config.js"

# The flags a generated config.js carries.
config_js_content() {
  printf 'var penpotFlags = "%s";\n' "${PDV_PENPOT_FLAGS:-enable-mcp}"
}

# config.js is gitignored and lives under resources/public, which a frontend
# build deletes whole, and the agentic frontend needs it to enable MCP. While
# the file exists, the tune keeps a snapshot of it in the instance's home; once
# a build has deleted it (or it is a symlink, which the container cannot
# follow out of the bind mount), the tune restores the snapshot. Without a
# snapshot it generates the file from PDV_PENPOT_FLAGS, but only for an
# agentic instance or when that variable is set.
tune_config_js() {
  local cfg="$DEST/$CONFIG_JS" snap="$CTR_STATE/config.js" state agentic=$AGENTIC
  state=$(docker exec "$CTR" sh -c '
    if [ -L "$1" ]; then echo link
    elif [ -f "$1" ]; then echo file
    elif [ -f "$2" ]; then echo restorable
    else echo missing; fi' _ "$cfg" "$snap" 2>/dev/null || true)
  case "$state" in
    file)
      docker exec "$CTR" sudo -EH -u penpot sh -c \
        'mkdir -p "$(dirname "$2")" && { cmp -s "$1" "$2" || cp "$1" "$2"; }' _ "$cfg" "$snap" \
        && vsay "tune: config.js present, snapshot kept in the instance home" \
        || warn "tune: could not snapshot config.js; a build that deletes it will not be repaired"
      return 0 ;;
    restorable)
      say "tune: config.js is missing, restoring the instance's snapshot"
      why "a frontend build deletes resources/public whole, and config.js is gitignored, so nothing else brings it back"
      docker exec "$CTR" cat "$snap" | ctr_write_file "$cfg" \
        || warn "tune: could not restore config.js from $snap"
      return 0 ;;
  esac
  # link, or missing with no snapshot.
  if ! $agentic && tmx list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx mcp; then
    agentic=true
  fi
  if ! $agentic && [ -z "${PDV_PENPOT_FLAGS:-}" ]; then
    vsay "tune: no config.js and nothing asks for one (not agentic, PDV_PENPOT_FLAGS unset)"
    return 0
  fi
  say "tune: writing config.js with flags '${PDV_PENPOT_FLAGS:-enable-mcp}'"
  why "the agentic frontend enables MCP only through config.js, and a symlink into a directory outside the bind mount dangles inside the container"
  config_js_content | ctr_write_file "$cfg" \
    || warn "tune: could not write config.js; the frontend will not enable MCP"
}

# Write stdin to a path inside the container, replacing whatever is there. As
# the container user first; a directory the host user made can carry an ACL
# mask of r-x, so the fallback writes as root and hands the file to the
# directory's owner.
ctr_write_file() {
  local content
  content=$(cat)
  printf '%s\n' "$content" | docker exec -i "$CTR" sudo -EH -u penpot sh -c \
    'mkdir -p "$(dirname "$1")" && rm -f "$1" && cat > "$1"' _ "$1" 2>/dev/null && return 0
  printf '%s\n' "$content" | docker exec -i "$CTR" sh -c \
    'd=$(dirname "$1"); mkdir -p "$d" && rm -f "$1" && cat > "$1" && chown --reference="$d" "$1"' _ "$1"
}

# clojure-lsp flags every RPC handler as an unused public var: the
# sv/defmethod hook declares a var per handler that only runtime dispatch
# resolves, and no clj-kondo setting reaches that linter. The setting goes in
# the container home, which clojure-lsp and Serena both read. A config the
# user wrote there is left alone.
tune_clojure_lsp() {
  local dst="/home/penpot/.config/clojure-lsp/config.edn" src="$PDV_SELF/share/clojure-lsp-config.edn" cur
  cur=$(docker exec "$CTR" sudo -EH -u penpot cat "$dst" 2>/dev/null || true)
  if [ -z "$cur" ]; then
    say "tune: writing $dst (unused-public-var off)"
    why "clojure-lsp flags every sv/defmethod handler as unused, because only runtime dispatch resolves the var the hook declares"
    docker exec -i "$CTR" sudo -EH -u penpot sh -c 'mkdir -p "$(dirname "$1")" && cat > "$1"' _ "$dst" <"$src" \
      || warn "tune: could not write $dst"
  elif grep -Eq ':clojure-lsp/unused-public-var[[:space:]]*\{[[:space:]]*:level[[:space:]]*:off' <<<"$cur"; then
    vsay "tune: $dst already turns unused-public-var off"
  else
    warn "tune: $dst is your own and keeps unused-public-var on; add the linter setting from $src to silence the RPC handlers"
  fi
}

# Claude Code reads skills only from .claude/skills, the repository keeps them
# in .agents/skills, and /.claude is gitignored. manage.sh seeds the link in
# wsN copies only, so ws0 and worktrees get it here. An existing path is never
# replaced.
tune_skills_link() {
  local tree link
  tree=$(mount_src "$CTR")
  [ -n "$tree" ] || return 0
  link="$tree/.claude/skills"
  if [ -e "$link" ] || [ -L "$link" ]; then
    vsay "tune: $link exists, nothing to do"
  elif [ ! -d "$tree/.agents/skills" ]; then
    vsay "tune: no .agents/skills in $tree, no skills link to make"
  else
    say "tune: linking .claude/skills -> ../.agents/skills in $tree"
    why "Claude Code reads skills only from .claude/skills, and the repository keeps them in .agents/skills"
    { mkdir -p "$tree/.claude" && ln -s ../.agents/skills "$link"; } || warn "tune: could not create $link"
  fi
}

# The image ships tmux.conf with mouse off and re-copies it on every start, so
# a setting made inside the container does not last. Opt-in, because it is a
# preference.
tune_tmux_mouse() {
  [ "${PDV_TMUX_MOUSE:-0}" = 1 ] || return 0
  say "tune: tmux mouse on (PDV_TMUX_MOUSE=1)"
  tmx set -g mouse on >/dev/null || warn "tune: could not turn the tmux mouse on (no session yet?)"
}

tune_instance() {
  tune_config_js
  tune_clojure_lsp
  tune_skills_link
  tune_tmux_mouse

  # The image vendors CARGO_HOME=/opt/cargo owned by root. Reads work, but a
  # Cargo.lock that needs a crate missing from the vendored set makes the
  # render-wasm build fail with 'Permission denied' on registry/cache. The
  # container's filesystem resets on recreate, so the fix is reapplied here.
  local owner
  owner=$(docker exec "$CTR" stat -c %U /opt/cargo 2>/dev/null || true)
  if [ "$owner" = "root" ]; then
    say "tune: chown -R penpot:users /opt/cargo (in the container)"
    why "the image's CARGO_HOME is root-owned, so render-wasm builds fail when they must fetch a crate the vendored set lacks"
    docker exec "$CTR" chown -R penpot:users /opt/cargo || warn "tune: chown of /opt/cargo failed; render-wasm builds fail on crates the vendored set lacks"
  elif [ -n "$owner" ]; then
    vsay "tune: /opt/cargo is owned by $owner, nothing to do"
  fi

  # The image pins the toolchain (Node, JDK, Rust, emscripten) and the code
  # comes from the bind mount, so a stale image shows up as toolchain errors
  # once the checkout expects a newer one. Advisory only.
  local img="$DEVENV_IMGNAME:$DEVENV_TAG" running_img local_id local_digest remote_digest
  local adopt="pdv pull-devenv && pdv stop --ws $WS_INDEX && pdv run --ws $WS_INDEX"
  running_img=$(docker inspect -f '{{.Image}}' "$CTR" 2>/dev/null || true)
  local_id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)
  if [ -n "$local_id" ] && [ -n "$running_img" ] && [ "$running_img" != "$local_id" ]; then
    warn "tune: $CTR runs an older $img than the one pulled locally; recreate it with: pdv run --ws $WS_INDEX --recreate"
  fi
  local_digest=$(docker image inspect -f '{{join .RepoDigests "\n"}}' "$img" 2>/dev/null | sed -n 's/^.*@//p' | head -1)
  remote_digest=$(docker buildx imagetools inspect "$img" --format '{{.Manifest.Digest}}' 2>/dev/null || true)
  if [ -z "$local_digest" ] || [ -z "$remote_digest" ]; then
    vsay "tune: image currency check skipped (registry unreachable, docker buildx missing, or a locally built image)"
  elif [ "$local_digest" = "$remote_digest" ]; then
    vsay "tune: $img is current (${local_digest:0:19})"
  else
    warn "tune: a newer $img is available upstream"
    imp "a mismatch shows as pnpm engine errors, UnsupportedClassVersionError in the backend, or render-wasm build failures"
    imp "adopting it removes the container and its tmux session, and keeps every volume: $adopt"
  fi
}
