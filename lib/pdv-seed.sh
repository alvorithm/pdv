#!/usr/bin/env bash
# pdv-seed.sh — the per-worktree database and bucket, the fixture profile that
# seeds them, and the host half of the seed driver protocol.
#
# Sourced by pdv, never executed. The contract is
# wip.local/20261117-pdv-seed/contract.md.
#
# pdv names the database and the bucket after the bound worktree, not after the
# ws number, so two worktrees on branches with different migrations never share
# a schema. The choice of profile and of an explicit database lives in the
# worktree's own git dir, so it is per worktree and never shows in git status.
#
# The container half is share/pdv-seed.bb (the driver) and share/seed.clj (the
# engine it loads into the backend). This file stages the profile, the fixture
# files, the downloads and the secrets the driver asks for, and it owns the
# database lifecycle around them.

: "${PDV_SELF:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# The shared database and bucket of the legacy devenv: the default until a run
# resolves a worktree, and the escape hatch (`--db penpot`) afterwards.
PDV_DB="${PDV_DB:-penpot}"
PDV_BUCKET="${PDV_BUCKET:-penpot}"

# Per-user defaults: ${XDG_CONFIG_HOME:-~/.config}/pdv/env holds PDV_*=value
# lines (no quotes, no expansion beyond a leading ~/). The environment wins.
seed_load_user_config() {
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/pdv/env" line key value
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^(PDV_[A-Z0-9_]+)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [ -z "${!key+x}" ] || continue
    case "$value" in "~/"*) value="$HOME/${value#\~/}" ;; esac
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done <"$f"
}
seed_load_user_config

PDV_FIXTURES="${PDV_FIXTURES:-$HOME/Code/penpot-fixtures}"
SEED_STAGE=/tmp/pdv-seed
SEED_TIMEOUT="${PDV_SEED_TIMEOUT:-900}"
SEED_ENABLED=true
SEED_TREE=""
SEED_PROFILE=""
SEED_PROFILE_FILE=""
SEED_INPUT_HASH=""
SEED_CACHE_PATH=""
# The command line's own choices, applied over the persisted ones.
SEED_ARG=""; SEED_ARG_SET=false
DB_ARG="";   DB_ARG_SET=false

# ---------------------------------------------------------------- the names
# Pure functions, so the parity harness can check them without a container.

# The worktree slug: lower-cased, every run of characters outside [a-z0-9]
# replaced by _, trimmed of _, truncated to 40. The database carries it with a
# `pdvwt_` prefix, the bucket with `pdvwt-` and every _ turned into -.
seed_slug() {
  local s=${1,,}
  s=${s//[^a-z0-9]/_}
  s=$(printf '%s' "$s" | sed -E 's/_{2,}/_/g; s/^_+//; s/_+$//')
  printf '%s' "${s:0:40}"
}

# A database name becomes a bucket name by turning every _ into - and
# lower-casing it: an S3 bucket forbids _ and upper case.
seed_bucket_for() {
  local b=${1//_/-}
  printf '%s' "${b,,}"
}

# The default database for a tree: pdvwt_<slug>.
seed_db_for_tree() {
  printf 'pdvwt_%s' "$(seed_slug "$(basename "$1")")"
}

seed_db_valid() {
  local n="$1"
  [ "${#n}" -ge 1 ] && [ "${#n}" -le 63 ] || return 1
  case "$n" in
    [a-z]*) ;;
    *) return 1 ;;
  esac
  case "$n" in
    *[!a-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# --------------------------------------------------------- the chosen state
# Stored in the worktree's own git dir: one line each, absent for the default.
seed_gitdir() {
  git -C "$1" rev-parse --absolute-git-dir 2>/dev/null || true
}

seed_state_file() {
  local g
  g=$(seed_gitdir "$1")
  [ -n "$g" ] || return 1
  printf '%s/%s' "$g" "$2"
}

seed_state_read() {
  local f
  f=$(seed_state_file "$1" "$2") || return 0
  [ -f "$f" ] && head -1 "$f" || true
}

seed_state_write() {
  local f
  if ! f=$(seed_state_file "$1" "$2"); then
    warn "seed: $1 is not a git worktree, so '$3' cannot be remembered for it"
    return 1
  fi
  printf '%s\n' "$3" >"$f" || { warn "seed: could not write $f"; return 1; }
}

seed_state_clear() {
  local f
  f=$(seed_state_file "$1" "$2") || return 0
  rm -f "$f"
}

# The tree the instance binds: ws0 is the resolved checkout, wsN is its slot,
# resolved through the symlink when the slot is one. A slot that does not exist
# yet is a copy manage.sh is about to make, and its basename names it.
seed_tree() {
  if [ "${WS_INDEX:-0}" = "0" ]; then
    printf '%s' "$ROOT"
    return 0
  fi
  local slot="${PENPOT_WORKSPACES_DIR:-}/$WS"
  if [ -e "$slot" ]; then
    readlink -f "$slot"
  else
    printf '%s' "$slot"
  fi
}

# The profile file: the fixture repository's profiles/<name>.yaml, or pdv's own
# share/default-profile.yaml when no profile is named.
seed_profile_file() {
  local name="$1"
  if [ -z "$name" ]; then
    printf '%s' "$PDV_SELF/share/default-profile.yaml"
    return 0
  fi
  [ -f "$PDV_FIXTURES/profiles/$name.yaml" ] || return 1
  printf '%s' "$PDV_FIXTURES/profiles/$name.yaml"
}

# The first team a profile declares. `pdv bundle save` wants a team name and
# the profile is where it is written down; the host has no YAML parser, so the
# one line the layout guarantees is read directly.
seed_profile_team() {
  [ -n "$SEED_PROFILE_FILE" ] && [ -f "$SEED_PROFILE_FILE" ] || return 1
  sed -n '/^teams:/,/^[a-z]/s/^[[:space:]]*-[[:space:]]*name:[[:space:]]*//p' "$SEED_PROFILE_FILE" \
    | head -1 | sed -E "s/^['\"]//; s/['\"]\$//"
}

# Resolves the persisted choice plus the command line's own into PDV_DB,
# PDV_BUCKET, SEED_PROFILE and SEED_PROFILE_FILE. Never creates anything.
seed_resolve_selection() {
  SEED_TREE=$(seed_tree)
  local slug db profile
  slug=$(seed_slug "$(basename "$SEED_TREE")")
  [ -n "$slug" ] \
    || die "seed: the directory name '$(basename "$SEED_TREE")' yields an empty slug (it needs a letter or a digit)"
  db=$(seed_state_read "$SEED_TREE" pdv-db)
  profile=$(seed_state_read "$SEED_TREE" pdv-seed)
  if $DB_ARG_SET; then
    if [ -z "$DB_ARG" ] || [ "$DB_ARG" = "default" ]; then
      db=""
    else
      db=$DB_ARG
    fi
  fi
  if $SEED_ARG_SET; then
    if [ "$SEED_ARG" = "none" ]; then profile=""; else profile=$SEED_ARG; fi
  fi

  [ -n "$db" ] || db="pdvwt_$slug"
  seed_db_valid "$db" \
    || die "seed: '$db' is not a usable database name (lower-case letters, digits, _ and -, at most 63 characters, starting with a letter)"
  PDV_DB=$db
  PDV_BUCKET=$(seed_bucket_for "$db")
  [ "${#PDV_BUCKET}" -ge 3 ] && [ "${#PDV_BUCKET}" -le 63 ] \
    || die "seed: the bucket name '$PDV_BUCKET' must be 3 to 63 characters, because the database name becomes the bucket name"
  case "$PDV_BUCKET" in
    *-) die "seed: the bucket name '$PDV_BUCKET' cannot end with a dash; name the database without the trailing _" ;;
  esac

  # PDV_SEED_DEFAULT names a fixtures profile for every run that chose none.
  if [ -z "$profile" ] && [ -n "${PDV_SEED_DEFAULT:-}" ]; then profile=$PDV_SEED_DEFAULT; fi
  SEED_PROFILE=$profile
  SEED_PROFILE_FILE=""
  SEED_ENABLED=true
  if [ "$PDV_DB" = "penpot" ]; then
    # The legacy shared database: never created, seeded, dropped or emptied.
    # The profile is still resolved, for `bundle save`'s team default.
    SEED_ENABLED=false
    SEED_PROFILE_FILE=$(seed_profile_file "$profile" 2>/dev/null || true)
    return 0
  fi
  if SEED_PROFILE_FILE=$(seed_profile_file "$profile"); then
    [ -f "$SEED_PROFILE_FILE" ] \
      || warn "seed: $SEED_PROFILE_FILE is missing; the profile cannot be staged"
  else
    SEED_PROFILE_FILE=""
    warn "seed: profile '$profile' is not in $PDV_FIXTURES/profiles"
  fi
  return 0
}

# Writes the command line's choices where the next run finds them.
seed_persist_selection() {
  [ -n "$SEED_TREE" ] || return 0
  if $SEED_ARG_SET; then
    if [ -z "$SEED_ARG" ] || [ "$SEED_ARG" = "none" ]; then
      seed_state_clear "$SEED_TREE" pdv-seed
    else
      seed_state_write "$SEED_TREE" pdv-seed "$SEED_ARG"
    fi
  fi
  if $DB_ARG_SET; then
    if [ -z "$DB_ARG" ] || [ "$DB_ARG" = "default" ]; then
      seed_state_clear "$SEED_TREE" pdv-db
    else
      seed_state_write "$SEED_TREE" pdv-db "$DB_ARG" || true
    fi
  fi
}

# ------------------------------------------------------------- the database
# The postgres container of the shared infra, resolved the way manage.sh's own
# ensure-instance-test-database resolves it.
seed_pg_container() {
  local c
  c=$(infra-compose ps -q postgres 2>/dev/null || true)
  [ -n "$c" ] || return 1
  printf '%s' "$c"
}

# One psql round-trip per call, against the server manage.sh created.
seed_psql() {
  local db="$1"; shift
  local pg
  pg=$(seed_pg_container) || { warn "seed: postgres container not found; is the shared infra up?"; return 1; }
  docker exec -e "PGPASSWORD=${PENPOT_DATABASE_PASSWORD:-penpot}" "$pg" \
    psql -h 127.0.0.1 -U "${PENPOT_DATABASE_USERNAME:-penpot}" -d "$db" \
         -v ON_ERROR_STOP=1 -tA "$@"
}

seed_db_exists() {
  [ "$(seed_psql postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'" 2>/dev/null || true)" = "1" ]
}

seed_meta_get() {
  seed_psql "$1" -c "SELECT value FROM pdv_meta WHERE key = '$2'" 2>/dev/null || true
}

# An empty database plus the two rows pdv owns. The backend's migrations ignore
# an unknown table, so this can precede the first start.
seed_db_create() {
  local db="$1" tree="$2" esc=${2//\'/\'\'}
  seed_psql postgres -c "CREATE DATABASE \"$db\"" >/dev/null \
    || die "seed: could not create the database $db"
  seed_psql "$db" -c \
    "CREATE TABLE IF NOT EXISTS pdv_meta(key text primary key, value text);
     INSERT INTO pdv_meta(key, value) VALUES ('worktree_path', '$esc') ON CONFLICT (key) DO NOTHING;
     INSERT INTO pdv_meta(key, value) VALUES ('created_at', now()::text) ON CONFLICT (key) DO NOTHING;" \
    >/dev/null || die "seed: could not record pdv_meta in $db"
  say "seed: created the database $db for $tree"
}

# Dropping needs every connection gone: a backend that is still up holds them.
seed_db_drop() {
  local db="$1"
  seed_psql postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" \
    >/dev/null 2>&1 || true
  seed_psql postgres -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null \
    || { warn "seed: could not drop the database $db"; return 1; }
  say "seed: dropped the database $db"
}

# ----------------------------------------------------------------- the bucket
# The backend creates the bucket at start (scripts/_env::setup_s3_bucket), so
# pdv only ever empties or removes one. Inside the running main container the
# aws CLI and the credentials are already there; without one, a one-shot
# container on the shared network reaches the same endpoint.
seed_aws() {
  if [ -n "${CTR:-}" ] && container_running "$CTR" 2>/dev/null; then
    docker exec "$CTR" aws "$@"
  else
    # manage.sh sources defaults.env into its own shell, so the devenv's S3
    # credentials are here but unexported. Exporting them for the one-shot
    # container keeps them off the command line.
    (
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
      docker run --rm --network "${DEVENV_NETWORK:-penpot_shared}" \
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
        --entrypoint aws "${DEVENV_IMGNAME:-penpotapp/devenv}:${DEVENV_TAG:-latest}" "$@"
    )
  fi
}

seed_bucket_exists() {
  seed_aws s3api head-bucket \
    --endpoint-url "$PENPOT_OBJECTS_STORAGE_S3_ENDPOINT" \
    --region "$PENPOT_OBJECTS_STORAGE_S3_REGION" \
    --bucket "$1" >/dev/null 2>&1
}

seed_bucket_empty() {
  local b="$1"
  seed_bucket_exists "$b" || return 0
  say "seed: emptying the bucket $b"
  seed_aws s3 rm "s3://$b" --recursive \
    --endpoint-url "$PENPOT_OBJECTS_STORAGE_S3_ENDPOINT" \
    --region "$PENPOT_OBJECTS_STORAGE_S3_REGION" >/dev/null \
    || { warn "seed: could not empty the bucket $b"; return 1; }
}

seed_bucket_drop() {
  local b="$1"
  seed_bucket_exists "$b" || return 0
  seed_aws s3 rb "s3://$b" --force \
    --endpoint-url "$PENPOT_OBJECTS_STORAGE_S3_ENDPOINT" \
    --region "$PENPOT_OBJECTS_STORAGE_S3_REGION" >/dev/null \
    || { warn "seed: could not remove the bucket $b"; return 1; }
}

# ------------------------------------------------------------- orphan sweep
# A worktree that is gone takes its data with it: nothing of it can be read
# again, so the database and the bucket go too. Batches of pdvwt_* databases
# whose pdv_meta.worktree_path no longer exists are swept; anything without
# that row was not created by pdv and is left alone. Best effort throughout.
seed_sweep_orphans() {
  local dbs db tree bucket dropped=0
  seed_pg_container >/dev/null || { vsay "sweep: postgres is not running, nothing to sweep"; return 0; }
  dbs=$(seed_psql postgres -c "SELECT datname FROM pg_database WHERE left(datname, 6) = 'pdvwt_'" 2>/dev/null || true)
  [ -n "$dbs" ] || { vsay "sweep: no per-worktree database exists yet"; return 0; }
  for db in $dbs; do
    tree=$(seed_meta_get "$db" worktree_path)
    if [ -z "$tree" ]; then
      vsay "sweep: $db has no pdv_meta.worktree_path, left alone"
      continue
    fi
    [ -d "$tree" ] && continue
    bucket=$(seed_bucket_for "$db")
    say "sweep: dropping $db, its worktree $tree is gone"
    if seed_db_drop "$db"; then
      seed_bucket_drop "$bucket" || warn "sweep: $db is gone but its bucket $bucket is not"
      dropped=$(( dropped + 1 ))
    else
      warn "sweep: could not drop $db"
    fi
  done
  [ "$dropped" -gt 0 ] && say "sweep: $dropped orphaned database(s) removed"
  return 0
}

# ------------------------------------------------------------ the download cache
# One host-wide cache under ${XDG_CACHE_HOME:-~/.cache}/pdv/remote, keyed by the
# driver's cache key: github-<owner>-<repo>-<oid> or sha256-<hex>.
seed_cache_dir() {
  printf '%s/pdv/remote' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

# Downloads on a miss only. The hash a profile pins is checked here, so a
# truncated or substituted download never reaches the container.
seed_cache_get() {
  local key="$1" url="$2" sha="$3" dir path tmp alt got
  dir=$(seed_cache_dir)
  mkdir -p "$dir"
  path="$dir/$key"
  if [ -f "$path" ]; then
    SEED_CACHE_PATH=$path
    vsay "seed: cached $key"
    return 0
  fi
  tmp=$(mktemp "$dir/.download.XXXXXX")
  say "seed: downloading $key"
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$url"; then
    case "$url" in
      https://media.githubusercontent.com/media/*)
        alt="https://raw.githubusercontent.com/${url#https://media.githubusercontent.com/media/}"
        say "seed: the media host refused $key, retrying through raw.githubusercontent.com"
        why "penpot-files keeps its files in LFS, and the media host forwards them; a repository without LFS serves raw instead"
        if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$alt"; then
          rm -f "$tmp"
          warn "seed: could not download $key from $url"
          return 1
        fi ;;
      *)
        rm -f "$tmp"
        warn "seed: could not download $key from $url"
        return 1 ;;
    esac
  fi
  if [ -n "$sha" ] && [ "$sha" != "-" ]; then
    got=$(sha256sum "$tmp" | cut -d' ' -f1)
    if [ "$got" != "$sha" ]; then
      rm -f "$tmp"
      warn "seed: $key downloaded with sha256 $got, the profile pins $sha"
      return 1
    fi
  fi
  mv "$tmp" "$path"
  SEED_CACHE_PATH=$path
  return 0
}

# --------------------------------------------------------------- the staging
# pdv copies the driver and the engine into the container before it asks the
# driver what to stage, then stages exactly that: repo paths, cache-keyed
# downloads, and secrets. One staging directory per call, reset once at its
# start and left alone afterwards, so the driver can read what `needs` wrote.
seed_stage_reset() {
  docker exec "$CTR" sudo chown -R penpot:users "$SEED_STAGE" 2>/dev/null || true
  docker exec "$CTR" sudo -EH -u penpot bash -c \
    'rm -rf "$1" && mkdir -p "$1/repo" "$1/remote" "$1/secret" "$1/out" && chmod 700 "$1" "$1/secret"' \
    _ "$SEED_STAGE" || { warn "seed: could not reset $SEED_STAGE in $CTR"; return 1; }
  docker cp "$PDV_SELF/share/pdv-seed.bb" "$CTR:$SEED_STAGE/pdv-seed.bb" >/dev/null \
    || { warn "seed: could not copy share/pdv-seed.bb into $CTR"; return 1; }
  docker cp "$PDV_SELF/share/seed.clj" "$CTR:$SEED_STAGE/seed.clj" >/dev/null \
    || { warn "seed: could not copy share/seed.clj into $CTR"; return 1; }
}

seed_stage_profile() {
  [ -f "$SEED_PROFILE_FILE" ] \
    || { warn "seed: no profile file to stage (looked for '${SEED_PROFILE:-default}')"; return 1; }
  docker cp "$SEED_PROFILE_FILE" "$CTR:$SEED_STAGE/profile.yaml" >/dev/null \
    || { warn "seed: could not stage $SEED_PROFILE_FILE"; return 1; }
}

seed_stage_repo() {
  local rel="${1%/}" src="$PDV_FIXTURES/${1%/}" parent
  [ -e "$src" ] || { warn "seed: $rel is not in the fixture repository $PDV_FIXTURES"; return 1; }
  parent=$(dirname "$SEED_STAGE/repo/$rel")
  docker exec "$CTR" sudo -EH -u penpot mkdir -p "$parent" \
    || { warn "seed: could not create $parent in $CTR"; return 1; }
  docker cp "$src" "$CTR:$SEED_STAGE/repo/$rel" >/dev/null \
    || { warn "seed: could not copy $src into $CTR"; return 1; }
}

seed_stage_remote() {
  local key="$1" url="$2" sha="$3"
  seed_cache_get "$key" "$url" "$sha" || return 1
  docker cp "$SEED_CACHE_PATH" "$CTR:$SEED_STAGE/remote/$key" >/dev/null \
    || { warn "seed: could not copy $SEED_CACHE_PATH into $CTR"; return 1; }
}

# A password_file is a host JSON object with a "password" field, and the
# container gets that field as JSON the driver reads. There is no jq on the
# host by contract, so the one field the file carries is read directly.
seed_secret_json() {
  local p="$1" json
  case "$p" in
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  [ -f "$p" ] || { warn "seed: password_file $1 does not exist"; return 1; }
  json=$(cat "$p")
  if [[ $json =~ \"password\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    local pw=${BASH_REMATCH[1]}
    pw=${pw//\\/\\\\}
    printf '{"password": "%s"}\n' "$pw"
  else
    warn "seed: password_file $1 has no \"password\" string field"
    return 1
  fi
}

seed_stage_secret() {
  local n="$1" hostpath="$2" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/pdv-secret.XXXXXX")
  chmod 600 "$tmp"
  if ! seed_secret_json "$hostpath" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! docker cp "$tmp" "$CTR:$SEED_STAGE/secret/$n" >/dev/null; then
    rm -f "$tmp"
    warn "seed: could not stage secret $n into $CTR"
    return 1
  fi
  rm -f "$tmp"
  docker exec "$CTR" chmod 600 "$SEED_STAGE/secret/$n" 2>/dev/null || true
}

seed_driver() {
  docker exec "$CTR" sudo -EH -u penpot bb "$SEED_STAGE/pdv-seed.bb" "$@"
}

# Stages everything `needs` asks for, then asks the driver for the input hash.
# Sets SEED_INPUT_HASH.
seed_stage_all() {
  local out kind a b c
  seed_stage_reset || return 1
  seed_stage_profile || return 1
  out=$(seed_driver needs) \
    || { warn "seed: the driver refused the profile '${SEED_PROFILE:-default}' (see its message above)"; return 1; }
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      '') ;;
      repo)   seed_stage_repo "$a" || return 1 ;;
      remote) seed_stage_remote "$a" "$b" "$c" || return 1 ;;
      secret) seed_stage_secret "$a" "$b" || return 1 ;;
      *)      warn "seed: the driver asked for an unknown staging entry '$kind'"; return 1 ;;
    esac
  done <<<"$out"
  docker exec "$CTR" sudo chown -R penpot:users "$SEED_STAGE" \
    || { warn "seed: could not hand $SEED_STAGE to the container user"; return 1; }
  SEED_INPUT_HASH=$(seed_driver hash) || { warn "seed: the driver could not hash the staged input"; return 1; }
  SEED_INPUT_HASH=${SEED_INPUT_HASH//[[:space:]]/}
  [ -n "$SEED_INPUT_HASH" ] || { warn "seed: the driver printed an empty input hash"; return 1; }
  vsay "seed: input hash $SEED_INPUT_HASH"
  return 0
}

# ------------------------------------------------------------ the lifecycle
# True when the database is absent or was seeded from a different input hash.
# A database pdv created but never seeded carries no hash: it is kept and
# seeded into, so an interrupted first run does not lose what it has.
seed_db_stale() {
  $SEED_ENABLED || return 1
  if ! seed_db_exists "$PDV_DB"; then return 0; fi
  local current
  current=$(seed_meta_get "$PDV_DB" input_hash)
  if [ -z "$current" ]; then return 1; fi
  if [ "$current" = "$SEED_INPUT_HASH" ]; then return 1; fi
  return 0
}

# Creates the database when absent and rebuilds it when the profile's input
# hash differs from the seeded one. Both happen before the backend starts, so
# migrations run against the schema the tree's branch expects.
seed_ensure_database() {
  $SEED_ENABLED || return 0
  if seed_db_exists "$PDV_DB"; then
    if ! seed_db_stale; then
      say "seed: $PDV_DB is up to date (hash $SEED_INPUT_HASH), nothing will be imported"
      return 0
    fi
    say "seed: the profile changed since the last seed — rebuilding $PDV_DB and the bucket $PDV_BUCKET"
    why "an import always assigns new file ids, so a changed profile is replayed into a fresh database rather than merged"
    seed_db_drop "$PDV_DB" || return 1
    seed_bucket_empty "$PDV_BUCKET" || true
  fi
  seed_db_create "$PDV_DB" "$SEED_TREE" || return 1
  return 0
}

# The same rebuild for a backend that is already running: a database with live
# connections cannot be dropped, so the backend window stops first and starts
# again on the rebuilt one.
seed_rebuild() {
  $SEED_ENABLED || return 0
  say "seed: stopping the backend window before $PDV_DB is rebuilt"
  why "postgres refuses to drop a database that a backend is connected to"
  # The caller's selection is the window plan; only the backend restarts here.
  SELECTED=(backend)
  stop_service backend
  seed_db_drop "$PDV_DB" || return 1
  seed_bucket_empty "$PDV_BUCKET" || true
  seed_db_create "$PDV_DB" "$SEED_TREE" || return 1
  seed_export_tmux_env
  start_service backend
  return 0
}

# The tmux session environment carries the database and the bucket, so a pane
# that restarts the backend by hand lands on the same ones the window would.
seed_export_tmux_env() {
  local ctr="${1:-$CTR}"
  container_running "$ctr" 2>/dev/null || return 0
  docker exec "$ctr" sudo -EH -u penpot tmux has-session -t "$SESSION" 2>/dev/null || return 0
  docker exec "$ctr" sudo -EH -u penpot tmux set-environment -t "$SESSION" \
    PENPOT_DATABASE_URI "postgresql://postgres/$PDV_DB" 2>/dev/null || true
  docker exec "$ctr" sudo -EH -u penpot tmux set-environment -t "$SESSION" \
    PENPOT_OBJECTS_STORAGE_S3_BUCKET "$PDV_BUCKET" 2>/dev/null || true
}

# Waits for the backend's nREPL socket, then for the migrations table the
# engine's project names carry. Both inside the running container.
seed_wait_backend() {
  local deadline=$(( SECONDS + SEED_TIMEOUT ))
  say "seed: waiting for the backend nREPL on port 6064 in $CTR (≤${SEED_TIMEOUT} s)"
  why "share/pdv-seed.bb evaluates the engine through the backend's nREPL, which exists only once app.main has started (port 6063 is Penpot's JSON command REPL, not a Clojure one)"
  while ! docker exec "$CTR" bash -c 'exec 3<>/dev/tcp/127.0.0.1/6064' 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      warn "seed: the backend nREPL did not answer within ${SEED_TIMEOUT} s"
      return 1
    fi
    sleep 2
  done
  # The table exists before the migration runner has applied every step, and
  # an import into a half-migrated schema would name its project after the
  # wrong head. Three equal counts a second apart are a settled schema.
  say "seed: waiting for the migrations in $PDV_DB to settle"
  local applied="" previous="__unread__" stable=0
  while :; do
    applied=$(seed_psql "$PDV_DB" -c "SELECT count(*) FROM migrations" 2>/dev/null || true)
    if [ -n "$applied" ] && [ "$applied" = "$previous" ]; then
      stable=$(( stable + 1 ))
      if [ "$stable" -ge 2 ]; then
        say "seed: $applied migration(s) applied"
        return 0
      fi
    else
      stable=0
    fi
    previous=$applied
    if [ "$SECONDS" -ge "$deadline" ]; then
      warn "seed: the migrations in $PDV_DB did not settle within ${SEED_TIMEOUT} s"
      return 1
    fi
    sleep 1
  done
}

# The window holds the backend only if the selection names it; on an already
# running instance the window itself answers.
seed_backend_selected() {
  if in_selection backend; then return 0; fi
  tmx list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx backend
}

# Applies the staged profile to the running backend. Its stdout is the result
# EDN, so it is captured and dropped; the driver's summary goes to stderr.
seed_apply() {
  local -a extra=()
  # The driver defaults the database to pdvwt_<slug>; say it when a --db
  # override made it another one.
  if [ "$PDV_DB" != "$(seed_db_for_tree "$SEED_TREE")" ]; then
    extra=(--database "$PDV_DB")
  fi
  # The engine records the profile name in pdv_meta.
  if [ -n "${SEED_PROFILE:-}" ]; then
    extra+=(--profile "$SEED_PROFILE")
  fi
  # Its stdout is the result EDN, which nothing on the host reads; the
  # driver's human summary goes to stderr.
  seed_driver apply --slug "$(seed_slug "$(basename "$SEED_TREE")")" \
    --hash "$SEED_INPUT_HASH" ${extra[@]+"${extra[@]}"} >/dev/null \
    || { warn "seed: the driver could not apply the profile (see its message above)"; return 1; }
  return 0
}

# Writes <tree>/.pdv-agent.json and keeps it out of git status. The file is a
# credential, so it is 600 and never printed.
seed_copy_agent_json() {
  local tree="$SEED_TREE" dest="$SEED_TREE/.pdv-agent.json" tmp common
  [ -n "$tree" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/pdv-agent.XXXXXX")
  if ! docker cp "$CTR:$SEED_STAGE/out/agent.json" "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    vsay "seed: no agent user in this profile, so no .pdv-agent.json"
    return 0
  fi
  chmod 600 "$tmp"
  if ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    warn "seed: could not write $dest"
    return 1
  fi
  say "seed: wrote $dest (mode 600)"
  common=$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -z "$common" ]; then
    warn "seed: $tree is not a git worktree, so .pdv-agent.json is not excluded from git status"
    return 0
  fi
  case "$common" in
    /*) ;;
    *) common="$tree/$common" ;;
  esac
  if mkdir -p "$common/info" 2>/dev/null && \
     ! grep -qxF '/.pdv-agent.json' "$common/info/exclude" 2>/dev/null; then
    printf '%s\n' '/.pdv-agent.json' >>"$common/info/exclude" \
      || warn "seed: could not add .pdv-agent.json to $common/info/exclude"
  fi
  return 0
}

# The database the live backend process connected to, read from its own
# environment. Empty while no backend JVM runs.
seed_live_backend_db() {
  container_running "${CTR:-}" 2>/dev/null || return 0
  docker exec "$CTR" sh -c '
    for p in $(pgrep -f "app[.]main" 2>/dev/null); do
      tr "\0" "\n" <"/proc/$p/environ" 2>/dev/null \
        | sed -n "s|^PENPOT_DATABASE_URI=postgresql://[^/]*/||p"
    done' 2>/dev/null | head -1 || true
}

# True when the running instance's backend is on this worktree's database, so
# a seed lands where pdv thinks it does.
seed_backend_on_pdv_db() {
  $SEED_ENABLED || return 1
  local live
  live=$(seed_live_backend_db)
  if [ -z "$live" ]; then
    vsay "seed: no backend JVM is up yet, so there is nothing to seed into"
    return 1
  fi
  [ "$live" = "$PDV_DB" ] && return 0
  warn "seed: the backend of $CTR is on the database $live, not $PDV_DB, so it was not seeded"
  imp "rebuild $PDV_DB and move the backend onto it: pdv seed --ws $WS_INDEX"
  return 1
}

# The whole post-start half: wait for the backend, apply, write the agent file.
# A failure warns and leaves the instance running; `pdv seed` retries it.
seed_after_start() {
  $SEED_ENABLED || return 0
  if ! seed_backend_selected; then
    vsay "seed: no backend window selected, so nothing was seeded"
    imp "seed later with: pdv start --services backend --ws $WS_INDEX, then pdv seed --ws $WS_INDEX"
    return 0
  fi
  say "seed: profile '${SEED_PROFILE:-default}' into $PDV_DB (bucket $PDV_BUCKET)"
  seed_wait_backend || {
    warn "seed: the instance is up but not seeded"
    imp "retry with: pdv seed --ws $WS_INDEX"
    return 1
  }
  seed_apply || {
    warn "seed: the profile did not apply; the instance is up"
    imp "retry with: pdv seed --ws $WS_INDEX"
    return 1
  }
  say "seed: applied the profile"
  seed_copy_agent_json || true
  return 0
}

# --------------------------------------------------------------- the commands
# pdv seed [--ws N] [NAME]: rebuild an instance's database from the profile and
# seed it again. The backend window stops first, because a database with live
# connections cannot be dropped, and starts again once it is rebuilt.
cmd_seed() {
  local name="${REST[0]:-}"
  [ "${#REST[@]}" -le 1 ] || svc_usage "seed: takes at most one profile name"
  if [ "$name" = "status" ]; then
    cmd_seed_status
    return $?
  fi
  manage_load
  resolve_cap
  if [ "${#REST[@]}" -eq 1 ]; then
    SEED_ARG=$name
    SEED_ARG_SET=true
  fi
  seed_resolve_selection
  seed_persist_selection || true
  container_running "$CTR" || die "seed: $CTR is not running — bring it up with: pdv run --ws $WS_INDEX"
  has_session || die "seed: $CTR has no tmux session '$SESSION' — start it with: pdv run --ws $WS_INDEX"
  if ! $SEED_ENABLED; then
    die "seed: this instance uses the shared database $PDV_DB, which pdv never seeds; remove the worktree's pdv-db file or pass --db NAME"
  fi
  say "seed: staging the profile '${SEED_PROFILE:-default}'"
  seed_stage_all || die "seed: staging failed"
  seed_rebuild || die "seed: could not rebuild $PDV_DB"
  seed_after_start || exit 1
}

# pdv seed status [--ws N]: what the database holds, from pdv_meta and
# pdv_seed_file through psql. Read-only, so it also works with the backend
# window stopped.
cmd_seed_status() {
  manage_load
  seed_resolve_selection
  local profile input_hash seeded schema recorded files row
  if ! $SEED_ENABLED; then
    say "seed status: $PDV_DB is the shared database; pdv does not seed it"
    return 0
  fi
  if ! seed_pg_container >/dev/null; then
    die "seed status: the shared postgres is not running"
  fi
  if ! seed_db_exists "$PDV_DB"; then
    say "seed status: $PDV_DB does not exist yet (worktree $SEED_TREE, bucket $PDV_BUCKET)"
    return 0
  fi
  profile=$(seed_meta_get "$PDV_DB" profile)
  input_hash=$(seed_meta_get "$PDV_DB" input_hash)
  seeded=$(seed_meta_get "$PDV_DB" seeded_at)
  schema=$(seed_meta_get "$PDV_DB" schema_head)
  recorded=$(seed_meta_get "$PDV_DB" worktree_path)
  say "seed status: $WS, database $PDV_DB, bucket $PDV_BUCKET"
  sub "profile:     ${profile:-${SEED_PROFILE:-none}}"
  sub "worktree:    ${recorded:-$SEED_TREE}"
  sub "hash:        ${input_hash:-<unseeded>}"
  sub "seeded at:   ${seeded:-<never>}"
  sub "schema head: ${schema:-<unknown>}"
  files=$(seed_psql "$PDV_DB" -c \
    "SELECT f.source || '  sha256=' || coalesce(f.sha256, '-') ||
            '  project=' || coalesce(p.name, f.project_id, '-') ||
            '  file=' || coalesce(f.file_id, '-')
       FROM pdv_seed_file AS f
       LEFT JOIN project AS p ON (p.id::text = f.project_id)
      ORDER BY f.source, f.imported_at, f.file_id" 2>/dev/null || true)
  if [ -n "$files" ]; then
    sub "files:"
    while IFS= read -r row; do sub "  $row"; done <<<"$files"
  else
    sub "files:       none recorded"
  fi
  return 0
}

# pdv bundle save <relpath> --project NAME [--team NAME] [--ws N]: export one
# project into the fixture repository. It never commits.
cmd_bundle() {
  local subcmd="${REST[0]:-}" relpath="" project="" team="" file dest i=1
  [ "$subcmd" = "save" ] \
    || svc_usage "bundle: only 'save' exists (pdv bundle save <relpath> --project NAME [--team NAME] [--ws N])"
  while [ "$i" -lt "${#REST[@]}" ]; do
    case "${REST[$i]}" in
      --project)   i=$(( i + 1 )); project="${REST[$i]:-}" ;;
      --project=*) project="${REST[$i]#--project=}" ;;
      --team)      i=$(( i + 1 )); team="${REST[$i]:-}" ;;
      --team=*)    team="${REST[$i]#--team=}" ;;
      -*)          svc_usage "bundle save: unknown flag ${REST[$i]}" ;;
      *)           [ -z "$relpath" ] || svc_usage "bundle save: takes one path, got '$relpath' and '${REST[$i]}'"
                   relpath="${REST[$i]}" ;;
    esac
    i=$(( i + 1 ))
  done
  [ -n "$relpath" ] || svc_usage "bundle save: needs a path under the fixture repository"
  [ -n "$project" ] || svc_usage "bundle save: needs --project NAME"
  manage_load
  seed_resolve_selection
  container_running "$CTR" || die "bundle save: $CTR is not running — bring it up with: pdv run --ws $WS_INDEX"
  if [ -z "$team" ]; then
    team=$(seed_profile_team) || true
    if [ -z "$team" ]; then
      svc_usage "bundle save: needs --team NAME (profile '${SEED_PROFILE:-default}' declares no team to default to)"
    fi
    say "bundle save: team '$team' (the first team of the profile)"
  fi
  [ -d "$PDV_FIXTURES" ] \
    || die "bundle save: $PDV_FIXTURES is not a checkout; clone the fixture repository there or set PDV_FIXTURES"
  case "$relpath" in
    *.penpot) file=$(basename "$relpath"); dest="$PDV_FIXTURES/$relpath" ;;
    *)        file="$project.penpot";       dest="$PDV_FIXTURES/${relpath%/}/$file" ;;
  esac
  seed_stage_reset || die "bundle save: could not stage the driver in $CTR"
  docker exec "$CTR" sudo -EH -u penpot mkdir -p "$SEED_STAGE/out" 2>/dev/null || true
  say "bundle save: exporting $team/$project"
  seed_driver export --team "$team" --project "$project" --out "$SEED_STAGE/out/$file" \
    || die "bundle save: the driver could not export $team/$project"
  mkdir -p "$(dirname "$dest")" || die "bundle save: could not create $(dirname "$dest")"
  local tmp
  tmp=$(mktemp -d)
  if ! docker cp "$CTR:$SEED_STAGE/out/$file" "$tmp/" >/dev/null 2>&1; then
    rm -rf "$tmp"
    die "bundle save: the driver wrote no $SEED_STAGE/out/$file"
  fi
  mv "$tmp/$file" "$dest" || { rm -rf "$tmp"; die "bundle save: could not write $dest"; }
  rm -rf "$tmp"
  say "bundle saved: $dest ($(du -h "$dest" | cut -f1))"
  sub "commit it in the fixture repository:"
  sub "  git -C $PDV_FIXTURES add ${relpath}"
  sub "  git -C $PDV_FIXTURES commit -m 'bundles: ${relpath}'"
}

# One line of `pdv status`: what the instance's tree has chosen.
seed_instance_line() {
  local tree="$1" db profile
  [ -n "$tree" ] || return 0
  # The mount source can be a workspace slot symlink (…/workspaces/ws5); the
  # name comes from the worktree it points at.
  tree=$(readlink -f "$tree")
  profile=$(seed_state_read "$tree" pdv-seed)
  db=$(seed_state_read "$tree" pdv-db)
  [ -n "$db" ] || db=$(seed_db_for_tree "$tree")
  sub "seed:    ${profile:-none}, db $db"
}
