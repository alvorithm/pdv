#!/usr/bin/env bash
# pdv-services.sh — the service vocabulary: which windows a selection owns,
# what each window runs, and the policy carried into it.
#
# Sourced by pdv after pdv-core.sh. One definition, because `run`, `start`,
# `stop` and `plan` must agree on a window's name, pane count and command.

# Canonical order. Window indexes compact from this order, and with the full
# set it reproduces start-tmux.sh's 0..5, which is what the parity harness
# compares.
PDV_SERVICES=(frontend storybook exporter backend mcp serena)
PDV_WATCHERS=(frontend storybook exporter)

SERVICE_WINDOW_frontend="frontend watch"
SERVICE_WINDOW_storybook="frontend storybook"
SERVICE_WINDOW_exporter="exporter"
SERVICE_WINDOW_backend="backend"
SERVICE_WINDOW_mcp="mcp"
SERVICE_WINDOW_serena="serena"

service_window() { local v="SERVICE_WINDOW_$1"; printf '%s' "${!v}"; }

# The service a window name belongs to; fails for a window pdv did not make.
window_service() {
  local s
  for s in "${PDV_SERVICES[@]}"; do
    if [ "$(service_window "$s")" = "$1" ]; then printf '%s' "$s"; return 0; fi
  done
  return 1
}

service_panes() {
  case "$1" in
    exporter) printf '2' ;;
    *)        printf '1' ;;
  esac
}

# The heap cap. -Xmx768m -Xms50m, carried in _JAVA_OPTIONS because the
# image's bashrc and backend/scripts/_env both re-export JAVA_OPTS (without
# -Xmx) and would drop anything passed there. JAVA_OPTS still gets the same
# value as best effort for the shadow-cljs scripts that read it before _env
# runs. An explicitly empty value means uncapped: the JVM default.
DEFAULT_JAVA_OPTS="-Xmx768m -Xms50m"
CAP=""
resolve_cap() {
  if [ "${PDV_JAVA_OPTS_GIVEN:-false}" = "true" ]; then
    CAP="${PDV_JAVA_OPTS:-}"
  elif [ -n "${DEVENV_JAVA_OPTS+set}" ]; then
    CAP="${DEVENV_JAVA_OPTS}"
  else
    CAP="$DEFAULT_JAVA_OPTS"
  fi
}

cap_prefix() {
  [ -n "$CAP" ] || return 0
  printf "_JAVA_OPTIONS=%s JAVA_OPTS=%s " "$(shquote "$CAP")" "$(shquote "$CAP")"
}

# The backend's cap: an explicit --java-opts or DEVENV_JAVA_OPTS wins, then a
# profile's backend_heap (SEED_BACKEND_HEAP, from lib/pdv-seed.sh), then the
# default. Only the backend imports fixtures, so only its window takes the
# profile's heap.
backend_cap() {
  if [ "${PDV_JAVA_OPTS_GIVEN:-false}" != "true" ] && [ -z "${DEVENV_JAVA_OPTS+set}" ] \
     && [ -n "${SEED_BACKEND_HEAP:-}" ]; then
    printf '%s' "-Xmx${SEED_BACKEND_HEAP} -Xms50m"
  else
    printf '%s' "$CAP"
  fi
}

backend_cap_prefix() {
  local cap
  cap=$(backend_cap)
  [ -n "$cap" ] || return 0
  printf "_JAVA_OPTIONS=%s JAVA_OPTS=%s " "$(shquote "$cap")" "$(shquote "$cap")"
}

# --------------------------------------------------------------- selection
# Parses a comma list against PDV_SERVICES. Sets SELECTED (array, canonical
# order) and stops on an unknown name.
select_services() {
  local spec="$1" s known found
  local -a want=()
  IFS=',' read -ra want <<<"$spec"
  [ "${#want[@]}" -gt 0 ] || svc_usage "empty --services value"
  SELECTED=()
  for s in "${want[@]}"; do
    s="${s// /}"
    [ -n "$s" ] || continue
    found=false
    for known in "${PDV_SERVICES[@]}"; do
      if [ "$s" = "$known" ]; then found=true; fi
    done
    $found || svc_usage "unknown service '$s' (valid: ${PDV_SERVICES[*]})"
    SELECTED+=("$s")
  done
  # Canonical order, no duplicates.
  local ordered=() k
  for k in "${PDV_SERVICES[@]}"; do
    for s in ${SELECTED[@]+"${SELECTED[@]}"}; do
      if [ "$s" = "$k" ]; then ordered+=("$k"); fi
    done
  done
  SELECTED=(${ordered[@]+"${ordered[@]}"})
  [ "${#SELECTED[@]}" -gt 0 ] || svc_usage "no services selected"
}

in_selection() {
  local s
  for s in ${SELECTED[@]+"${SELECTED[@]}"}; do
    if [ "$s" = "$1" ]; then return 0; fi
  done
  return 1
}

# `run` and `start` compile the storybook target inside the frontend watcher,
# so a storybook window with no frontend watcher would show nothing new.
require_storybook_pairing() {
  if in_selection storybook && ! in_selection frontend; then
    svc_usage "storybook needs the frontend watcher that compiles it: add frontend to --services"
  fi
}

# The default service set: everything start-tmux.sh creates, so a bare
# `pdv run` is the upstream instance. Agentic bring-up adds the two windows
# that only exist in that mode.
default_services() {
  local s out=()
  for s in frontend storybook exporter backend; do out+=("$s"); done
  if [ "${AGENTIC:-false}" = "true" ]; then out+=(mcp serena); fi
  printf '%s' "$(IFS=,; echo "${out[*]}")"
}

# --------------------------------------------------------------- commands
# Emits the in-container command for one window (pane 0). Cache policy:
# upstream's `./scripts/watch app` always runs clear:shadow-cache, clear:wasm
# and build:wasm, which costs a Skia rebuild (minutes) on every start. pdv
# keeps the caches and only builds wasm when its artifact is missing; --clean
# restores the three upstream steps exactly.
CLEAN=false
want_clean() { [ "$CLEAN" = "true" ]; }

frontend_prefix() {
  if want_clean; then
    printf 'pnpm run clear:shadow-cache && pnpm run clear:wasm && pnpm run build:wasm && '
  else
    printf '{ [ -f resources/public/js/render-wasm.wasm ] || pnpm run build:wasm; } && '
  fi
}

shadow_targets() {
  if in_selection storybook; then
    printf 'main worker storybook'
  else
    printf 'main worker'
  fi
}

window_command() {
  local svc="$1" prefix
  prefix=$(cap_prefix)
  case "$svc" in
    frontend)
      printf 'cd ~/penpot/frontend && %s%spnpm exec concurrently --kill-others-on-fail "pnpm run watch:app:assets" "clojure -M:dev:shadow-cljs watch %s" "pnpm run watch:app:libs"' \
        "$(frontend_prefix)" "$prefix" "$(shadow_targets)" ;;
    storybook)
      printf 'cd ~/penpot/frontend && %s./scripts/watch storybook' "$prefix" ;;
    exporter)
      printf 'cd ~/penpot/exporter && rm -f target/app.js* && %s./scripts/watch' "$prefix" ;;
    backend)
      printf 'cd ~/penpot/backend && %s%s./scripts/start-dev' "$(backend_cap_prefix)" "$(backend_prefix)" ;;
    mcp)
      printf 'cd ~/penpot/mcp && ./scripts/setup && pnpm run build && ./scripts/start-mcp-devenv' ;;
    serena)
      printf 'serena start-mcp-server --transport streamable-http --port 14281 --project penpot --context %s --host 0.0.0.0' \
        "${SERENA_CONTEXT:-desktop-app}" ;;
    *) svc_usage "unknown service '$svc'" ;;
  esac
}

# The devenv runs no admin-console (Nitrate) service, and the backend turns
# the module on by default, so every get-profile fails with "nitrate is
# unreachable". scripts/_env appends its own flags after an incoming
# PENPOT_FLAGS and never names the admin-console, and _env.local is sourced
# later, so a developer's `enable-admin-console` there still wins. The `$` is
# literal here: the container shell expands it.
backend_prefix() {
  printf '%s ' "PENPOT_DATABASE_URI=postgresql://postgres/${PDV_DB:-penpot}" \
                "PENPOT_OBJECTS_STORAGE_S3_BUCKET=${PDV_BUCKET:-penpot}" \
                'PENPOT_FLAGS="${PENPOT_FLAGS:-} disable-admin-console"'
}

# The exporter window carries a second pane that waits for the build.
exporter_second_command() {
  printf 'cd ~/penpot/exporter && ./scripts/wait-and-start.sh'
}

# What a start runs before any window command exists (upstream's start-tmux.sh
# does the same two setups): node dependencies, and the mcp bundle.
needs_frontend_setup() { in_selection frontend || in_selection storybook; }

# ------------------------------------------------------------- the plan
# One line per pane: index<TAB>window<TAB>pane<TAB>command. The offline parity
# check compares the window/pane columns with start-tmux.sh's own plan, and the
# adoption checks read the commands (cache policy, heap cap).
render_plan() {
  local i=0 svc
  for svc in ${SELECTED[@]+"${SELECTED[@]}"}; do
    printf '%s\t%s\t%s\t%s\n' "$i" "$(service_window "$svc")" 0 "$(window_command "$svc")"
    if [ "$svc" = exporter ]; then
      printf '%s\t%s\t%s\t%s\n' "$i" "$(service_window "$svc")" 1 "$(exporter_second_command)"
    fi
    i=$(( i + 1 ))
  done
}

# The detached in-container script `pdv run` launches: session first (so
# attach works while setups run, as start-tmux.sh does), then the requested
# services' setups, then the windows.
render_start_script() {
  local svc cmd
  cat <<'HEAD'
#!/usr/bin/env bash
sudo chown penpot:users /home/penpot 2>/dev/null || true
cd ~
source ~/.bashrc
SESSION=penpot
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[pdv] reusing existing tmux session '$SESSION'"
  exit 0
fi
tmux -2 new-session -d -s "$SESSION"
HEAD
  # The worktree's database and bucket belong to the session as well: a pane
  # that restarts the backend by hand must land on the same ones the window
  # command carries. lib/pdv-seed.sh owns both values.
  printf 'tmux set-environment -t "$SESSION" PENPOT_DATABASE_URI %q\n' \
    "postgresql://postgres/${PDV_DB:-penpot}"
  printf 'tmux set-environment -t "$SESSION" PENPOT_OBJECTS_STORAGE_S3_BUCKET %q\n' \
    "${PDV_BUCKET:-penpot}"
  if needs_frontend_setup; then
    printf 'pushd ~/penpot/frontend >/dev/null && ./scripts/setup; popd >/dev/null\n'
  fi
  if in_selection exporter; then
    printf 'pushd ~/penpot/exporter >/dev/null && ./scripts/setup; popd >/dev/null\n'
  fi
  cat <<'MID'
IDX=0
add_window() {
  local name="$1" cmd="$2"
  if [ "$IDX" -eq 0 ]; then
    tmux rename-window -t "$SESSION:0" "$name"
  else
    tmux new-window -t "$SESSION:$IDX" -n "$name"
  fi
  tmux send-keys -t "$SESSION:$IDX" "$cmd" Enter
  IDX=$(( IDX + 1 ))
}
MID
  for svc in ${SELECTED[@]+"${SELECTED[@]}"}; do
    cmd=$(window_command "$svc")
    printf 'CMD=%q\n' "$cmd"
    printf 'add_window %q "$CMD"\n' "$(service_window "$svc")"
    if [ "$svc" = exporter ]; then
      printf 'tmux split-window -v -t "$SESSION"\n'
      printf 'CMD=%q\n' "$(exporter_second_command)"
      printf 'tmux send-keys -t "$SESSION:$(( IDX - 1 ))" "$CMD" Enter\n'
    fi
  done
  cat <<'TAIL'
tmux select-window -t "$SESSION:0"
echo "[pdv] tmux session '$SESSION' has $(tmux list-windows -t "$SESSION" | wc -l) windows"
TAIL
}

# ------------------------------------------------------- start/stop windows
# Start one window's panes on a running instance: create the window when it is
# absent, then type the service command into each idle pane. A busy pane is
# reported and left alone, so this is also the cheap "what is running?".
# STARTED_ANY turns true when a command was typed into a pane.
# A pane spends its first seconds inside the image's bashrc (emsdk_env.sh and
# the pnpm PATH setup), and that child is startup work rather than a service.
# Read pane_busy only after the shell settles, or a just-created window is
# misread as already running and the service is skipped.
wait_pane_settled() {
  local pid="$1" deadline=$(( SECONDS + ${2:-15} ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane_busy "$pid" >/dev/null || return 0
    sleep 0.5
  done
  return 1
}

# Upstream installs the frontend and exporter dependencies before any window
# exists. An instance brought up backend-only never did, so starting a watcher
# there would send the command into a tree with no node_modules and the pane
# would die on its first `pnpm exec`. The setup is idempotent and cheap when
# the dependencies are already there.
ensure_node_deps() {
  local svc="$1" dir
  case "$svc" in
    frontend|storybook) dir=frontend ;;
    exporter)           dir=exporter ;;
    *)                  return 0 ;;
  esac
  if docker exec "$CTR" sudo -EH -u penpot bash -c "[ -d ~/penpot/$dir/node_modules ]" 2>/dev/null; then
    return 0
  fi
  say "window '$(service_window "$svc")': $dir/node_modules is missing — running ./scripts/setup first"
  why "upstream installs these before any window exists; a backend-only run never did"
  as_penpot "cd ~/penpot/$dir && ./scripts/setup" \
    || warn "$dir setup failed; the window's command will probably fail with a missing dependency"
}

STARTED_ANY=false

start_service() {
  local svc="$1" win cmd pane pid desc i=0 next fresh window_fresh=false
  local -a entries=() commands=()
  win=$(service_window "$svc")
  if ! tmx list-windows -t "$SESSION" -F '#{window_name}' >/dev/null 2>&1; then
    warn "instance $CTR has no tmux session '$SESSION' — start it with: pdv run --ws $WS_INDEX"
    return 1
  fi
  ensure_node_deps "$svc"
  if ! tmx list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "$win"; then
    next=$(tmx list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null | sort -n | tail -1)
    next=$(( ${next:--1} + 1 ))
    say "creating window '$win'"
    tmx new-window -t "$SESSION:$next" -n "$win"
    window_fresh=true
  fi
  commands=("$(window_command "$svc")")
  if [ "$svc" = exporter ]; then commands+=("$(exporter_second_command)"); fi
  mapfile -t entries < <(tmx list-panes -t "$SESSION:$win" -F '#{pane_id} #{pane_pid}')
  for cmd in "${commands[@]}"; do
    fresh=$window_fresh
    if [ "$i" -ge "${#entries[@]}" ]; then
      if [ "$svc" = exporter ] && [ "$i" -eq 1 ]; then
        tmx split-window -v -t "$SESSION:$win"
        mapfile -t entries < <(tmx list-panes -t "$SESSION:$win" -F '#{pane_id} #{pane_pid}')
        fresh=true
      else
        warn "window '$win' has no pane $i for: $cmd"
        i=$(( i + 1 )); continue
      fi
    fi
    read -r pane pid <<<"${entries[$i]}"
    if $fresh; then wait_pane_settled "$pid" 15 || true; fi
    if desc=$(pane_busy "$pid"); then
      say "window '$win' pane $i: already running '$(printf '%.60s' "$desc")' — leaving it"
    else
      say "window '$win' pane $i: starting $cmd"
      tmx send-keys -t "$pane" "$cmd" Enter
      STARTED_ANY=true
    fi
    i=$(( i + 1 ))
  done
}

# Stop one window's busy panes with C-c, keeping the window and its shells, so
# `pdv start` revives it without a container restart.
stop_service() {
  local svc="$1" win pane pid busy tries desc
  win=$(service_window "$svc")
  if ! tmx list-panes -t "$SESSION:$win" >/dev/null 2>&1; then
    say "window '$win': not present, skipping"
    return 0
  fi
  busy=false
  while read -r pane pid; do
    if desc=$(pane_busy "$pid"); then
      say "window '$win': stopping '$(printf '%.60s' "$desc")' (pane $pane, ~$(pane_tree_rss_mb "$pid") MB resident)"
      tmx send-keys -t "$pane" C-c
      busy=true
    fi
  done < <(tmx list-panes -t "$SESSION:$win" -F '#{pane_id} #{pane_pid}')
  $busy || { say "window '$win': already stopped"; return 0; }
  for tries in $(seq 1 20); do
    sleep 0.5
    busy=false
    while read -r pane pid; do
      if pane_busy "$pid" >/dev/null; then busy=true; fi
      if [ "$tries" -eq 10 ] && pane_busy "$pid" >/dev/null; then tmx send-keys -t "$pane" C-c; fi
    done < <(tmx list-panes -t "$SESSION:$win" -F '#{pane_id} #{pane_pid}')
    $busy || { say "window '$win': stopped"; return 0; }
  done
  warn "window '$win': still busy after C-c twice — inspect it in tmux"
}

# ------------------------------------------------------------ pane liveness
# Every pane of a service window that has stopped: an idle shell, or a pane
# whose process is gone. A stopped watcher is a deliberate `pdv stop`, or it
# died; either way the UI serves whatever bundle is on disk. One exec per
# instance, so the busy test (pane_busy's) runs inside the container.
status_idle_panes() {
  local name="$1" idx="$2" tree="$3" win pane svc flag="" frontend=false
  [ "$idx" = 0 ] || flag=" --ws $idx"
  while IFS='|' read -r win pane; do
    [ -n "$win" ] || continue
    svc=$(window_service "$win") || continue
    subwarn "window '$win' pane $pane is not running anything (stopped with pdv stop, or it died)"
    imp "start it: pdv start --services $svc$flag"
  done < <(docker exec "$name" sudo -EH -u penpot bash -c '
    tmux list-panes -s -t "$1" -F "#{window_name}|#{pane_index}|#{pane_pid}" 2>/dev/null |
    while IFS="|" read -r w i p; do
      comm=$(ps -o comm= -p "$p" 2>/dev/null)
      if [ -z "$comm" ]; then echo "$w|$i"; continue; fi
      case "$comm" in
        bash|sh|zsh|dash|fish) [ -n "$(ps --ppid "$p" -o pid= 2>/dev/null)" ] || echo "$w|$i" ;;
      esac
    done' _ "$SESSION" 2>/dev/null || true)
  # No bundle at all costs the whole page, not only live recompiles.
  if docker exec "$name" sudo -EH -u penpot tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null \
       | grep -qxF "$(service_window frontend)"; then
    frontend=true
  fi
  if $frontend && [ -n "$tree" ] && [ ! -f "$tree/frontend/resources/public/js/main.js" ]; then
    subwarn "no frontend bundle on disk: the UI is a blank page until the watcher's first compile lands"
  fi
}

# ------------------------------------------------------------ the bundle
# What the UI serves when no frontend watcher runs: the bundle under
# frontend/resources/public/js, judged from the host tree. Prints `none` (no
# main.js), `dev` (a watcher's build, which leaves cljs-runtime/ beside
# main.js), `stale <path>` (a source file newer than main.js), or `current`.
# Read-only, so `pdv status` reports it for every instance.
frontend_bundle_state() {
  local tree="$1" js="$1/frontend/resources/public/js" newer
  if [ ! -f "$js/main.js" ]; then echo none; return 0; fi
  if [ -d "$js/cljs-runtime" ]; then echo dev; return 0; fi
  newer=$(find "$tree/frontend/src" "$tree/frontend/resources/styles" "$tree/frontend/translations" \
            "$tree/common/src" -type f -newer "$js/main.js" -print -quit 2>/dev/null || true)
  if [ -n "$newer" ]; then echo "stale ${newer#"$tree"/}"; else echo current; fi
}

bundle_state_text() {
  case "$1" in
    none)     echo "no bundle on disk, so the page is blank" ;;
    dev)      echo "a watcher's dev build, which shows a red 'Reconnecting...' overlay while no frontend watcher runs" ;;
    stale\ *) echo "a release bundle older than ${1#stale }" ;;
    current)  echo "a current release bundle" ;;
  esac
}

# ------------------------------------------------------ the watcher modes
# `pdv stop --watchers` is backend-only work: the shadow-cljs JVM and the node
# watchers hold 5 to 10 GiB, and the backend, common, and REPL work needs none
# of it. What it costs is live frontend recompilation, so the UI then serves
# the bundle on disk. These follow-ups tell the developer what that bundle is,
# offer the build that makes it current, keep the backend up, and print the
# way back. `pdv start --watchers` is the way back.
selection_is_watchers() {
  [ "${SELECTED[*]-}" = "${PDV_WATCHERS[*]}" ]
}

ui_url() { printf 'https://localhost:%s' "$(( 3449 + WS_INDEX * 10000 ))"; }

# $1: auto (ask on a tty when the bundle is not current), force, or skip.
watchers_stopped() {
  local policy="$1" tree state build=false ans
  tree=$(mount_src "$CTR")
  state=$(frontend_bundle_state "$tree")
  say "bundle: $(bundle_state_text "$state")"
  why "with no watcher, the UI serves the bundle under frontend/resources/public/js; a stale or dev bundle hides every frontend change made since it was built"
  if [ "$policy" = force ]; then
    build=true
  elif [ "$state" != current ]; then
    if [ "$policy" = skip ]; then
      vsay "bundle: not building, as --no-build asks"
    elif [ -t 0 ]; then
      read -r -p "[pdv] run ./scripts/build app now (minutes; wipes node_modules and resources/public)? [y/N] " ans
      if [ "${ans,,}" = y ]; then build=true; fi
    else
      warn "no terminal to ask on, so nothing was built; build with: pdv build-frontend --ws $WS_INDEX"
    fi
  fi
  if $build; then
    frontend_build || warn "the UI serves whatever the failed build left; retry with: pdv build-frontend --ws $WS_INDEX"
  fi
  ensure_backend_up || true
  say "done: $CTR runs without frontend watchers"
  sub "UI now:           $(ui_url)  ($(bundle_state_text "$(frontend_bundle_state "$tree")"))"
  sub "frontend change:  pdv build-frontend --ws $WS_INDEX (minutes), or pdv start --watchers --ws $WS_INDEX (about 30 s to compile)"
  sub "backend restart:  pdv restart --services backend --ws $WS_INDEX"
  sub "REPL for editors: pdv repl --ws $WS_INDEX (host port $(( 6064 + WS_INDEX * 10000 )))"
}

watchers_started() {
  if ! $STARTED_ANY; then
    say "done: nothing to start, the watchers were already running"
    return 0
  fi
  say "done: started the panes marked 'starting' above; the first compile takes about 30 s"
  why "until that compile lands, the UI serves whatever bundle is on disk, so a reload before then shows the old code"
  imp "the compile replaces a release bundle with a dev build, so a later pdv stop --watchers offers the build again"
  sub "watch progress:   pdv attach --ws $WS_INDEX (window '$(service_window frontend)')"
  sub "UI:               $(ui_url) (hard-reload once the compile lands)"
  sub "backend only:     pdv stop --watchers --ws $WS_INDEX"
}

# The backend's uREPL on 6062 opens when the JVM is up, so an answering
# connect is the liveness signal. A running backend is left untouched, and so
# is a busy pane whose port is still closed, which is a backend still starting.
UREPL_PORT=6062
ensure_backend_up() {
  local pid desc deadline
  if repl_up "$UREPL_PORT"; then
    say "backend is up (uREPL :$UREPL_PORT answering)"
    return 0
  fi
  pid=$(tmx list-panes -t "$SESSION:$(service_window backend)" -F '#{pane_pid}' 2>/dev/null | head -1 || true)
  if [ -n "$pid" ] && desc=$(pane_busy "$pid"); then
    warn "the backend pane runs '$(printf '%.60s' "$desc")' but uREPL :$UREPL_PORT is closed; it is probably still starting, so pdv leaves it alone"
    return 0
  fi
  say "backend: not running, starting it"
  why "backend-only work still needs the backend JVM"
  seed_resolve_selection
  start_service backend || return 1
  say "waiting for uREPL :$UREPL_PORT in $CTR (≤300 s)"
  deadline=$(( SECONDS + 300 ))
  until repl_up "$UREPL_PORT"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      warn "the backend did not open uREPL :$UREPL_PORT within 300 s; inspect it with: pdv attach --ws $WS_INDEX"
      return 1
    fi
    sleep 3
  done
  say "backend is up (uREPL :$UREPL_PORT answering)"
}

# The release build. `./scripts/build app` deletes frontend/node_modules and
# frontend/resources/public before it rebuilds them (and the mcp and plugins
# node_modules too), so it refuses to run while a frontend or storybook
# watcher does. The config.js snapshot is refreshed first, so the repair
# restores the file the developer had.
frontend_build() {
  local rc=0 busy
  busy=$(busy_frontend_watchers)
  if [ -n "$busy" ]; then
    warn "build: not building while a watcher runs (services: $busy); stop it with: pdv stop --watchers --ws $WS_INDEX"
    return 3
  fi
  tune_config_js
  say "build: ./scripts/build app in $CTR, as penpot (takes minutes)"
  why "a release build carries no shadow-cljs devtools client, so the UI works with no watcher and without the 'Reconnecting...' overlay"
  imp "it wipes frontend/node_modules and frontend/resources/public first; the repairs follow it, and open tabs need a hard reload afterwards"
  as_penpot "cd ~/penpot/frontend && ./scripts/build app" || rc=$?
  say "build repair 1/2: chmod o+w frontend/resources/public and public/js, in the container, as their owner"
  why "the build recreates both as the container user; under rootless Docker the host user is 'other' there, and pdv run --agentic writes config.js into public/js from the host"
  as_penpot "chmod o+w $DEST/frontend/resources/public $DEST/frontend/resources/public/js" \
    || warn "build repair: chmod failed, so the host cannot write into frontend/resources/public/js"
  say "build repair 2/2: config.js"
  why "the build deleted resources/public whole, and config.js is gitignored, so no Penpot step brings it back. The tune restores the snapshot if the file is still missing, and keeps a copy written meanwhile"
  tune_config_js
  if [ "$rc" -ne 0 ]; then
    warn "build: ./scripts/build app failed (exit $rc)"
    return 1
  fi
  say "build: done"
}

# The services among frontend and storybook whose window has a busy pane,
# space-separated. Both read and write frontend/node_modules.
busy_frontend_watchers() {
  local svc pid out=()
  for svc in frontend storybook; do
    pid=$(tmx list-panes -t "$SESSION:$(service_window "$svc")" -F '#{pane_pid}' 2>/dev/null | head -1 || true)
    if [ -n "$pid" ] && pane_busy "$pid" >/dev/null; then out+=("$svc"); fi
  done
  printf '%s' "${out[*]-}"
}
