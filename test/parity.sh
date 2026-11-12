#!/usr/bin/env bash
# parity.sh — the regression net for pdv: the same instance as upstream's
# manage.sh run-devenv, asserted mechanically.
#
# Offline (default): pdv's window plan against the plan start-tmux.sh creates,
# plus the service, cache, heap and selector rules. No container is touched.
#
# Live (--live): for each workspace, bring the instance up with pdv run and
# again with ./manage.sh run-devenv, then compare the container state, the
# published ports, the mounts and the tmux window set. A bare pdv run claims
# to be the upstream instance, so upstream is the reference. pdv runs first
# because it grants the ACL a rootless daemon needs, which upstream does not.
# With --fast, also prove the
# adoption rules that only a running instance can show: --recreate keeps the
# volumes, the tune repairs config.js, clojure-lsp and the skills link, the
# heap cap reaches the JVMs, and status reports a stopped instance without
# attaching.
#
# Rootful docker is a separate daemon: --rootful runs the live matrix against
# /var/run/docker.sock. The chosen workspaces must be stopped on the rootless
# daemon first, because both daemons publish the same host ports.
#
# Usage: test/parity.sh [--offline] [--live] [--fast] [--ws 0,1]
#                       [--repo PATH] [--plain|--agentic] [--rootful]
#                       [--socket PATH] [--timeout SECONDS]
#
# Exit: 0 when every check passes (skips do not fail), 1 on any failure.

set -uo pipefail

SELF=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
PDV="$SELF/../pdv"
MODE=offline
WSD="0,1"
REPO="${PENPOT_REPO:-}"
AGENTIC=true
ROOTFUL=false
SOCKET=/var/run/docker.sock
TIMEOUT=900
FAST=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --offline)  MODE=offline ;;
    --live)     MODE=live ;;
    --fast)     FAST=true ;;
    --ws)       WSD="$2"; shift ;;
    --repo)     REPO="$2"; shift ;;
    --plain)    AGENTIC=false ;;
    --agentic)  AGENTIC=true ;;
    --rootful)  ROOTFUL=true ;;
    --socket)   SOCKET="$2"; shift ;;
    --timeout)  TIMEOUT="$2"; shift ;;
    -h|--help)  sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "parity: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

pass=0 fail=0 skipped=0
ok()   { pass=$(( pass + 1 ));    printf 'ok   %s\n' "$*"; }
bad()  { fail=$(( fail + 1 ));    printf 'FAIL %s\n' "$*"; }
skip() { skipped=$(( skipped + 1 )); printf 'skip %s\n' "$*"; }

# ---------------------------------------------------------------- the repo
for cand in "$REPO" "$(git rev-parse --show-toplevel 2>/dev/null)" "$HOME/Code/penpot"; do
  [ -n "$cand" ] || continue
  if [ -x "$cand/manage.sh" ] && [ -f "$cand/docker/devenv/docker-compose.main.yml" ]; then
    ROOT=$(cd "$cand" && pwd); break
  fi
done
[ -n "${ROOT:-}" ] || { echo "parity: no Penpot checkout (pass --repo PATH)" >&2; exit 2; }

START_TMUX="$ROOT/docker/devenv/files/start-tmux.sh"
AGENTIC_FLAG=""; $AGENTIC && AGENTIC_FLAG="--agentic"
if $AGENTIC && [ ! -f "$ROOT/frontend/resources/public/js/config.js" ]; then
  echo "parity: $ROOT/frontend/resources/public/js/config.js is missing; use --plain for a non-agentic comparison" >&2
  exit 2
fi

# ------------------------------------------------------------- docker target
DOCKER_HOST_FOR_RUN=""
if $ROOTFUL; then
  DOCKER_HOST_FOR_RUN="unix://$SOCKET"
  if ! docker -H "$DOCKER_HOST_FOR_RUN" info >/dev/null 2>&1; then
    skip "rootful docker at $SOCKET is not reachable; the rootful matrix is unproven here"
    printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
    exit 0
  fi
  # The tools drive docker themselves, so the daemon
  # has to travel in the environment, not only in this script's wrapper.
  export DOCKER_HOST="$DOCKER_HOST_FOR_RUN"
fi
dk() { docker "$@"; }

# ------------------------------------------------------- plan extraction
# The plan start-tmux.sh creates, read from its own lines: index 0 is renamed
# into place, later windows carry -n NAME, and split-window adds a pane to the
# window it follows.
upstream_plan() {
  local line idx name seen=0 last=""
  while IFS= read -r line; do
    case "$line" in
      *rename-window*)
        name=$(printf '%s' "$line" | sed -n "s/.*'\([^']*\)'.*/\1/p")
        [ -n "$name" ] && printf '0\t%s\t1\n' "$name"; last=0; seen=1 ;;
      *new-window*)
        idx=$(printf '%s' "$line" | sed -n 's/.*PENPOT_TMUX_SESSION:\([0-9][0-9]*\).*/\1/p')
        name=$(printf '%s' "$line" | sed -n "s/.*-n '\([^']*\)'.*/\1/p")
        [ -n "$idx" ] && [ -n "$name" ] && printf '%s\t%s\t1\n' "$idx" "$name"; last="$idx"; seen=1 ;;
      *split-window*)
        [ -n "$last" ] && printf '%s\tPANE\t%s\n' "$last" "$last" ;;
    esac
  done <"$START_TMUX"
}

# Collapses pdv plan's per-pane rows into the same index/name/panes shape.
pdv_window_plan() {
  local -a args=("$@")
  "$PDV" plan ${args[@]+"${args[@]}"} 2>/dev/null | awk -F'\t' '
    { if (NR == 1 || $1 != last) { if (NR > 1) printf "%s\t%s\t%d\n", last, name, panes; last=$1; name=$2; panes=0 }
      panes++ }
    END { if (NR > 0) printf "%s\t%s\t%d\n", last, name, panes }'
}

upstream_panes() {
  local idx="$1" panes=1
  panes=$(( 1 + $(upstream_plan | awk -F'\t' -v i="$idx" '$1==i && $2=="PANE"' | wc -l) ))
  printf '%s' "$panes"
}

upstream_window_plan() {
  upstream_plan | awk -F'\t' '$2!="PANE"' | while IFS=$'\t' read -r idx name _; do
    printf '%s\t%s\t%s\n' "$idx" "$name" "$(upstream_panes "$idx")"
  done
}

compare_plans() {
  local label="$1" want="$2" got="$3"
  if diff -u <(printf '%s\n' "$want") <(printf '%s\n' "$got") >/tmp/parity-plan.diff 2>&1; then
    ok "$label"
  else
    bad "$label"
    sed 's/^/     /' /tmp/parity-plan.diff
  fi
}

# ------------------------------------------------------------ offline checks
check_plan_parity() {
  local want got
  want=$(upstream_window_plan)
  # start-tmux.sh fixes every window in one script; the mcp and serena
  # windows are conditional on its environment, so the script's own plan is
  # the agentic one. The non-agentic selection is checked below.
  got=$(pdv_window_plan --agentic)
  compare_plans "window plan matches start-tmux.sh" "$want" "$got"
  compare_plans "a plain run leaves the agentic windows out" \
    "0	frontend watch	1
1	frontend storybook	1
2	exporter	2
3	backend	1" "$(pdv_window_plan)"
}

check_selection() {
  local plan
  plan=$(pdv_window_plan --services frontend,backend)
  compare_plans "run --services frontend,backend owns two windows" \
    "0	frontend watch	1
1	backend	1" "$plan"
  plan=$("$PDV" plan --services frontend,backend | awk -F'\t' '$2=="frontend watch"{print $4}')
  case "$plan" in
    *"watch main worker storybook"*) bad "frontend,backend must not compile the storybook target" ;;
    *"watch main worker"*) ok "frontend,backend compiles main and worker only" ;;
    *) bad "frontend watcher command missing its shadow-cljs targets: $plan" ;;
  esac
  plan=$("$PDV" plan --services frontend,storybook,backend | awk -F'\t' '$2=="frontend watch"{print $4}')
  case "$plan" in
    *"watch main worker storybook"*) ok "storybook in the selection restores the compile target" ;;
    *) bad "storybook selected but the frontend watcher does not compile it: $plan" ;;
  esac
  if "$PDV" plan --services storybook >/dev/null 2>&1; then
    bad "storybook without frontend must be refused"
  else
    ok "storybook without frontend is refused"
  fi
  compare_plans "--only-backend is the backend selector" \
    "0	backend	1" "$(pdv_window_plan --only-backend)"
  compare_plans "--watchers is the frontend,storybook,exporter shorthand" \
    "0	frontend watch	1
1	frontend storybook	1
2	exporter	2" "$(pdv_window_plan --watchers)"
}

check_cache_policy() {
  local cmd
  cmd=$("$PDV" plan | awk -F'\t' '$2=="frontend watch"{print $4}')
  case "$cmd" in
    *clear:shadow-cache*) bad "default frontend start must not clear the shadow cache" ;;
    *render-wasm.wasm*)   ok "default frontend start keeps caches and builds wasm only when missing" ;;
    *) bad "default frontend start lost the wasm presence check: $cmd" ;;
  esac
  cmd=$("$PDV" plan --clean | awk -F'\t' '$2=="frontend watch"{print $4}')
  case "$cmd" in
    *clear:shadow-cache*clear:wasm*build:wasm*)
      ok "--clean restores the upstream clear/build steps in order" ;;
    *) bad "--clean must clear shadow cache, clear wasm and rebuild: $cmd" ;;
  esac
}

check_heap_cap() {
  local cmd
  cmd=$("$PDV" plan | awk -F'\t' '$2=="frontend watch"{print $4}' | head -1)
  if printf '%s' "$cmd" | grep -qF "_JAVA_OPTIONS='-Xmx768m -Xms50m'"; then
    ok "the default cap is -Xmx768m -Xms50m carried in _JAVA_OPTIONS"
  else
    bad "default frontend command does not carry the heap cap: $cmd"
  fi
  if printf '%s' "$cmd" | grep -qF "_JAVA_OPTIONS"; then
    ok "the cap reaches the pane as an environment prefix"
  else
    bad "the frontend command has no environment prefix at all: $cmd"
  fi
  cmd=$("$PDV" plan --java-opts "" | awk -F'\t' '$2=="frontend watch"{print $4}')
  if printf '%s' "$cmd" | grep -qF "_JAVA_OPTIONS"; then
    bad "--java-opts '' must run uncapped: $cmd"
  else
    ok "--java-opts '' restores the uncapped default"
  fi
  cmd=$(DEVENV_JAVA_OPTS="-Xmx2g -Xms64m" "$PDV" plan | awk -F'\t' '$2=="frontend watch"{print $4}')
  if printf '%s' "$cmd" | grep -qF "Xmx2g"; then
    ok "DEVENV_JAVA_OPTS overrides the default cap"
  else
    bad "DEVENV_JAVA_OPTS did not reach the frontend command: $cmd"
  fi
  cmd=$("$PDV" plan --java-opts "-Xmx1g" | awk -F'\t' '$2=="frontend watch"{print $4}')
  local backend
  backend=$("$PDV" plan --java-opts "-Xmx1g" | awk -F'\t' '$2=="backend"{print $4}')
  if printf '%s%s' "$cmd" "$backend" | grep -qF "Xmx1g" && \
     printf '%s\n%s' "$cmd" "$backend" | grep -cF "Xmx1g" | grep -qx 2; then
    ok "--java-opts overrides the cap on every JVM window"
  else
    bad "--java-opts did not reach every JVM window: $backend"
  fi
}

check_instance_validation() {
  local out rc gcfg max
  max=$(sed -n 's/^PENPOT_MAX_WS_INDEX=\([0-9][0-9]*\).*/\1/p' "$ROOT/manage.sh" | head -1)
  # manage.sh appends safe.directory to the global git config on every run.
  gcfg=$(mktemp "${TMPDIR:-/tmp}/parity-gitconfig.XXXXXX")
  out=$( cd "$ROOT" && GIT_CONFIG_GLOBAL="$gcfg" ./manage.sh run-devenv --ws 9 2>&1 ); rc=$?
  rm -f "$gcfg"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "max supported is --ws $max"; then
    ok "manage.sh refuses --ws 9 at its ceiling of $max"
  else
    bad "manage.sh --ws 9 did not refuse as expected (rc=$rc)"
  fi
  out=$("$PDV" plan --ws 9 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "caps workspaces at $max"; then
    ok "pdv refuses --ws 9 with manage.sh's ceiling"
  else
    bad "pdv --ws 9 did not refuse as expected (rc=$rc)"
  fi
}

# --------------------------------------------------------------- live checks
CTR_FOR() { printf 'penpot-devenv-ws%s-main' "$1"; }

capture() {
  local n="$1" ctr
  ctr=$(CTR_FOR "$n")
  echo "container $ctr"
  echo "state $(dk inspect -f '{{.State.Status}} running={{.State.Running}} exit={{.State.ExitCode}}' "$ctr" 2>/dev/null)"
  echo "image $(dk inspect -f '{{.Config.Image}}' "$ctr" 2>/dev/null)"
  echo "ports"
  dk port "$ctr" 2>/dev/null | sort
  echo "mounts"
  dk inspect -f '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Destination}}|{{.Source}}{{println}}{{end}}' "$ctr" 2>/dev/null | sort
  echo "windows"
  dk exec "$ctr" sudo -EH -u penpot tmux list-windows -t penpot \
    -F '#{window_index} #{window_name} #{window_panes}' 2>/dev/null | sort -n
}

teardown() {
  local ctr
  ctr=$(CTR_FOR "$1")
  dk rm -f "$ctr" >/dev/null 2>&1 || true
}

expected_windows() {
  # pdv_window_plan collapses the per-pane plan to one row per window.
  pdv_window_plan $AGENTIC_FLAG | wc -l
}

wait_windows() {
  local n="$1" ctr want stable=0 last=-1 count deadline
  ctr=$(CTR_FOR "$n")
  want=$(expected_windows)
  deadline=$(( SECONDS + TIMEOUT ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! dk exec "$ctr" true >/dev/null 2>&1; then
      sleep 2; continue
    fi
    count=$(dk exec "$ctr" sudo -EH -u penpot tmux list-windows -t penpot -F '#{window_index}' 2>/dev/null | wc -l)
    if [ "$count" -eq "$want" ]; then
      stable=$(( stable + 2 ))
      [ "$stable" -ge 4 ] && return 0
    else
      stable=0
    fi
    last="$count"
    sleep 2
  done
  return 1
}

run_tool() {
  local tool="$1" n="$2" log="$3"
  case "$tool" in
    reference)
      # manage.sh appends safe.directory to the global git config on every
      # run; a snapshot keeps the harness from growing that file.
      local gcfg
      gcfg=$(mktemp "${TMPDIR:-/tmp}/parity-gitconfig.XXXXXX")
      if [ -f "$HOME/.config/git/config" ]; then cp "$HOME/.config/git/config" "$gcfg"; fi
      ( cd "$ROOT" && GIT_CONFIG_GLOBAL="$gcfg" ./manage.sh run-devenv --ws "$n" $AGENTIC_FLAG ) >"$log" 2>&1
      local rc=$?
      rm -f "$gcfg"
      return "$rc" ;;
    pdv)
      ( cd "$ROOT" && "$PDV" run --ws "$n" $AGENTIC_FLAG ) >"$log" 2>&1 ;;
  esac
}

recording() {
  local tool="$1" n="$2" log="$3" out="$4"
  teardown "$n"
  if ! run_tool "$tool" "$n" "$log"; then
    bad "$tool run --ws $n exited non-zero (log: $log)"
    tail -20 "$log" | sed 's/^/     /'
    return 1
  fi
  if ! wait_windows "$n"; then
    bad "$tool ws$n did not reach $(expected_windows) windows in ${TIMEOUT}s (log: $log)"
    capture "$n" | sed 's/^/     /'
    return 1
  fi
  capture "$n" >"$out"
}

check_live_ws() {
  local n="$1" o p
  o=$(mktemp); p=$(mktemp)
  local ol="$o.log" pl="$p.log"
  if ! recording pdv "$n" "$pl" "$p"; then rm -f "$o" "$p" "$ol" "$pl"; return 1; fi
  if ! recording reference "$n" "$ol" "$o"; then rm -f "$o" "$p" "$ol" "$pl"; return 1; fi
  if diff -u "$o" "$p" >/tmp/parity-live-$n.diff 2>&1; then
    ok "ws$n: container state, published ports, mounts and window set match manage.sh run-devenv"
  else
    bad "ws$n: pdv differs from manage.sh run-devenv"
    sed 's/^/     /' "/tmp/parity-live-$n.diff"
  fi
  rm -f "$o" "$p" "$ol" "$pl"
}

check_recreate() {
  local n="$1" ctr id1 id2 vols1 vols2
  ctr=$(CTR_FOR "$n")
  id1=$(dk inspect -f '{{.Id}}' "$ctr" 2>/dev/null)
  [ -n "$id1" ] || { skip "ws$n: --recreate needs a running instance from the parity check"; return 0; }
  vols1=$(dk inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}} {{end}}{{end}}' "$ctr" | tr ' ' '\n' | sort)
  ( cd "$ROOT" && "$PDV" run --ws "$n" --recreate $AGENTIC_FLAG ) >/tmp/parity-recreate-$n.log 2>&1 \
    || { bad "ws$n: pdv run --recreate exited non-zero"; tail -20 "/tmp/parity-recreate-$n.log" | sed 's/^/     /'; return 1; }
  id2=$(dk inspect -f '{{.Id}}' "$ctr" 2>/dev/null)
  vols2=$(dk inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}} {{end}}{{end}}' "$ctr" | tr ' ' '\n' | sort)
  if [ -n "$id2" ] && [ "$id1" != "$id2" ] && [ "$vols1" = "$vols2" ]; then
    ok "ws$n: --recreate rebuilt the container and kept every volume"
  else
    bad "ws$n: --recreate did not rebuild the container, or changed its volumes"
  fi
}

check_cap_live() {
  local n="$1" ctr deadline found=false
  ctr=$(CTR_FOR "$n")
  deadline=$(( SECONDS + 180 ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if dk exec "$ctr" sudo -EH -u penpot bash -c '
         for p in $(pgrep -u penpot -f "java|shadow-cljs" 2>/dev/null); do
           tr "\0" "\n" <"/proc/$p/environ" 2>/dev/null | grep -qx "_JAVA_OPTIONS=-Xmx768m -Xms50m" && exit 0
         done; exit 1' >/dev/null 2>&1; then
      found=true; break
    fi
    sleep 5
  done
  if $found; then
    ok "ws$n: a watcher JVM carries _JAVA_OPTIONS=-Xmx768m -Xms50m"
  else
    bad "ws$n: no JVM in the instance carries the heap cap within 180 s"
  fi
}

# The tune's repairs: a deleted config.js comes back from the snapshot, the
# clojure-lsp setting is in the container home, and the skills link exists.
check_tune_live() {
  local n="$1" ctr cfg tree before after out
  ctr=$(CTR_FOR "$n")
  cfg=/home/penpot/penpot/frontend/resources/public/js/config.js
  dk exec "$ctr" true >/dev/null 2>&1 || { skip "ws$n: the tune checks need a running instance"; return 0; }
  before=$(dk exec "$ctr" cat "$cfg" 2>/dev/null || true)
  if [ -n "$before" ]; then
    # As root: a host-made public/js can mask the container user's write bit.
    dk exec "$ctr" rm -f "$cfg"
    if dk exec "$ctr" test -e "$cfg"; then
      bad "ws$n: config.js survived its deletion, so the restore cannot be proven"
      return 1
    fi
  fi
  out=$( ( cd "$ROOT" && "$PDV" tune --ws "$n" ) 2>&1 ) || { bad "ws$n: pdv tune exited non-zero"; printf '%s\n' "$out" | sed 's/^/     /'; return 1; }
  if [ -z "$before" ]; then
    skip "ws$n: no config.js in the tree, so its restore is unproven here (use --agentic)"
  else
    after=$(dk exec "$ctr" cat "$cfg" 2>/dev/null || true)
    if [ "$after" = "$before" ]; then
      ok "ws$n: tune restores a deleted config.js from the instance's snapshot"
    else
      bad "ws$n: config.js was not restored as it was (after: '${after:-<missing>}')"
    fi
  fi
  if dk exec "$ctr" sudo -EH -u penpot cat /home/penpot/.config/clojure-lsp/config.edn 2>/dev/null \
       | grep -Eq ':clojure-lsp/unused-public-var[[:space:]]*\{[[:space:]]*:level[[:space:]]*:off'; then
    ok "ws$n: the container home turns clojure-lsp's unused-public-var off"
  else
    bad "ws$n: the container home's clojure-lsp config does not turn unused-public-var off"
  fi
  tree=$(dk inspect -f '{{range .Mounts}}{{if eq .Destination "/home/penpot/penpot"}}{{.Source}}{{end}}{{end}}' "$ctr")
  if [ ! -d "$tree/.agents/skills" ]; then
    skip "ws$n: the tree has no .agents/skills, so the skills link is unproven here"
  elif [ -d "$tree/.claude/skills" ]; then
    ok "ws$n: .claude/skills resolves to a directory in the bound tree"
  else
    bad "ws$n: .claude/skills is missing or dangling in $tree"
  fi
}

check_status_broken() {
  local n="$1" ctr out rc
  ctr=$(CTR_FOR "$n")
  dk stop "$ctr" >/dev/null 2>&1 || true
  out=$( ( cd "$ROOT" && "$PDV" status --ws "$n" ) 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'status=exited' && printf '%s' "$out" | grep -q 'logs:'; then
    ok "ws$n: status reports a stopped instance with its state and a logs tail"
  else
    bad "ws$n: status did not report the stopped instance as expected (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
  teardown "$n"
}

# ------------------------------------------------------------------- main
if [ "$MODE" = "offline" ]; then
  check_plan_parity
  check_selection
  check_cache_policy
  check_heap_cap
  check_instance_validation
else
  IFS=',' read -ra WS_LIST <<<"$WSD"
  for n in "${WS_LIST[@]}"; do
    check_live_ws "$n"
    if $FAST; then
      check_recreate "$n"
      check_tune_live "$n"
      check_cap_live "$n"
      check_status_broken "$n"
    else
      teardown "$n"
    fi
  done
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ] || exit 1
exit 0
