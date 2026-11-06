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
      printf 'cd ~/penpot/backend && %s./scripts/start-dev' "$prefix" ;;
    mcp)
      printf 'cd ~/penpot/mcp && ./scripts/setup && pnpm run build && ./scripts/start-mcp-devenv' ;;
    serena)
      printf 'serena start-mcp-server --transport streamable-http --port 14281 --project penpot --context %s --host 0.0.0.0' \
        "${SERENA_CONTEXT:-desktop-app}" ;;
    *) svc_usage "unknown service '$svc'" ;;
  esac
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
