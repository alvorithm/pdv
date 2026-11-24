#!/usr/bin/env bash
# pdv-tools.sh — the developer tools on a running instance: the persistent
# test JVM, Clojure evaluation, the editor REPL bridge and language server,
# the job table, the frontend release build, and the bug-report checklist.
#
# Sourced by pdv after pdv-core.sh, pdv-services.sh and pdv-seed.sh. The
# in-container halves live in share/ (testjvm.clj, testjvm-log4j2.xml,
# nrepl-client.py, lsp-bridge.py) and travel as `docker exec` arguments,
# because pdv's checkout is not mounted in the container. The host half of
# the REPL bridge is lib/repl-bridge.py.

# --------------------------------------------------------- caller's instance
# testjvm, eval, repl, lsp, jobs, build-frontend and bug-report act on the
# instance that serves the caller's worktree: `--ws N` names one, else the
# running instance whose bind mount resolves to the git toplevel of the
# directory pdv was called from (CALLER_DIR, captured before pdv changes
# directory). One `docker inspect` covers every name manage.sh can create.
# Sets CTR, WS, WS_INDEX, HOST_ROOT and WS_FLAG and prints the banner;
# returns 3 when no running instance qualifies, after naming the ones that
# run and what each serves.
select_caller_instance() {
  local want="" name running src list="" i
  local -a names=()
  for (( i = 0; i <= WS_MAX; i++ )); do names+=("penpot-devenv-ws$i-main"); done
  HOST_ROOT=""
  if $WS_GIVEN; then
    container_running "$CTR" && HOST_ROOT=$(mount_src "$CTR")
  else
    CTR=""
    want=$(git -C "$CALLER_DIR" rev-parse --show-toplevel 2>/dev/null) && want=$(readlink -f "$want") || want=""
  fi
  while read -r name running src; do
    name="${name#/}"
    [ "$running" = true ] && [ -n "$src" ] || continue
    if ! $WS_GIVEN && [ -n "$want" ] && [ "$(readlink -f "$src")" = "$want" ]; then
      CTR="$name" HOST_ROOT="$src"
      break
    fi
    list+="${list:+; }$name serves $(readlink -f "$src")"
  done < <(docker inspect -f '{{.Name}} {{.State.Running}} {{range .Mounts}}{{if eq .Destination "'"$DEST"'"}}{{.Source}}{{end}}{{end}}' \
             "${names[@]}" 2>/dev/null || true)
  if [ -z "$HOST_ROOT" ]; then
    if $WS_GIVEN; then
      warn "$CTR is not running, or does not mount $DEST"
    else
      warn "no running instance serves ${want:-$CALLER_DIR, which is not inside a git worktree}"
    fi
    if [ -n "$list" ]; then
      warn "running instances: $list"
      warn "pass --ws N to use one of them, or run this from the worktree an instance serves"
    else
      warn "no instance is running; start one with: pdv run"
    fi
    return 3
  fi
  WS_INDEX="${CTR#penpot-devenv-ws}"; WS_INDEX="${WS_INDEX%-main}"
  WS="ws$WS_INDEX"
  WS_FLAG=""; [ "$WS_INDEX" = 0 ] || WS_FLAG=" --ws $WS_INDEX"
  say "instance: $CTR  (worktree: $HOST_ROOT)"
  if $WS_GIVEN; then
    why "--ws $WS_INDEX names it"
  else
    why "the running instance whose $DEST bind mount resolves to this worktree; --ws N picks another"
  fi
}

# Every nREPL call goes through this client, run with the container's python3.
nrepl_client_src() { cat "$PDV_SELF/share/nrepl-client.py"; }

# ------------------------------------------------------------- the test JVM
# One JVM on the backend's :dev:test classpath stays up inside the instance
# (`-M:dev:test` plus a -Sdeps alias carrying clj-reload, whose :main-opts
# replace kaocha.runner) and answers over nREPL on 127.0.0.1:6065 there.
# Each run reloads the namespaces whose files changed, plus the loaded
# namespaces that depend on them, then runs kaocha with the repository's
# tests.edn and the focus ids given. run, reload and cold hold
# /tmp/penpot-backend-test.lock inside the container, because every run on
# an instance shares its test database.
TJ_PORT=6065
TJ_CDIR=/tmp/penpot-testjvm                  # inside the container
TJ_STORAGE="/tmp/penpot $DEST/backend/assets"
# The client waits this long past a run's deadline: no test starts after
# the deadline, but the one running finishes first. Past it the client
# interrupts the evaluation and exits 4.
TJ_MARGIN=30
# -Xmx: live heap after GC peaked at 333 MB over whole-suite runs and
# reloads; 2 GB leaves room for a heavy test. Without a cap the JVM sizes
# itself from the host and sits in swap when idle.
TJ_JVM_OPTS='"-Xmx2g" "-XX:MaxMetaspaceSize=1g" "-XX:+ExitOnOutOfMemoryError" "-XX:G1PeriodicGCInterval=300000" "-Djdk.attach.allowAttachSelf" "-Dlog4j2.configurationFile='$TJ_CDIR'/log4j2.xml"'
TJ_SDEPS='{:aliases {:testjvm {:extra-deps {io.github.tonsky/clj-reload {:mvn/version "1.0.0"}} :jvm-opts ['$TJ_JVM_OPTS'] :main-opts ["-i" "'$TJ_CDIR'/testjvm.clj"]}}}'

# Sourced by the in-container scripts below: the pid of the test JVM, a
# java process of penpot's that runs testjvm.clj (never a cat, tee, or
# editor that names the file), preferring the pid file the JVM writes when
# it is ready; and PENPOT_FLAGS with enable-backend-asserts, because
# app.config compiles every `assert` out without it, unlike CI.
TJ_IN_CTR_LIB='
jvm_pid() {
  local p
  for p in $(cat '$TJ_CDIR'/jvm.pid 2>/dev/null) $(pgrep -u penpot -x java); do
    case "$(tr "\0" " " 2>/dev/null < /proc/$p/cmdline)" in
      *" -i '$TJ_CDIR'/testjvm.clj"*) echo "$p"; return 0 ;;
    esac
  done
  return 1
}
case " ${PENPOT_FLAGS:-} " in
  *" enable-backend-asserts "*) ;;
  *) export PENPOT_FLAGS="${PENPOT_FLAGS:+$PENPOT_FLAGS }enable-backend-asserts" ;;
esac
'

# Inside the container: take the instance's backend test lock, record the
# holder, then exec the command, which inherits the lock. Prints one line
# while it waits and the holder when it gives up (4). Args: deadline (epoch
# s), holder description, margin (when set, the command is the nREPL client
# and gets --timeout up to deadline + margin), command…
TJ_LOCKED='
deadline=$1 what=$2 margin=$3; shift 3
lock=/tmp/penpot-backend-test.lock holder=/tmp/penpot-backend-test.holder
held_by() {
  local pid started desc
  read -r pid started desc < "$holder" 2>/dev/null
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    echo "$desc started $(( $(date +%s) - started )) s ago"
  else
    echo "a process that took $lock without pdv testjvm"
  fi
}
[ -e "$lock" ] || : > "$lock" 2>/dev/null
exec 9< "$lock" || { echo "[testjvm] harness error: cannot open $lock"; exit 6; }
if ! flock -n 9; then
  echo "[testjvm] waiting for $(held_by)"
  wait=$(( deadline - $(date +%s) )); [ "$wait" -gt 0 ] || wait=0
  flock -w "$wait" -E 4 9; rc=$?
  if [ "$rc" = 4 ]; then echo "[testjvm] gave up waiting for $(held_by)"; exit 4; fi
  [ "$rc" = 0 ] || { echo "[testjvm] harness error: flock exited $rc"; exit 6; }
fi
echo "$$ $(date +%s) $what" 2>/dev/null > "$holder"
[ -z "$margin" ] || set -- "$@" --timeout "$(( deadline + margin - $(date +%s) ))"
exec "$@"
'

# As root inside the container: hand what root created under the storage
# directories back to penpot, and count it by type (d, f, l).
TJ_REPAIR='find "$@" ! -user penpot -printf "%y\n" -exec chown -h penpot:penpot {} + 2>/dev/null | sort | uniq -c'

# Inside the container, as penpot, in backend/: start the JVM unless it is
# up or starting, then wait for its pid file. Exits 10 when it was already
# up, 6 when it died during start (log tail printed), 4 after 600 s.
TJ_LAUNCH='
cdir=$1 sdeps=$2 server=$3 log4j=$4
'"$TJ_IN_CTR_LIB"'
if pid=$(jvm_pid); then
  if [ "$(cat "$cdir/jvm.pid" 2>/dev/null)" = "$pid" ]; then echo "already up (pid $pid)"; exit 10; fi
  echo "a test JVM is already starting (pid $pid); waiting for it"
else
  mkdir -p "$cdir"
  printf "%s\n" "$server" > "$cdir/testjvm.clj"
  printf "%s\n" "$log4j" > "$cdir/log4j2.xml"
  rm -f "$cdir/jvm.pid"
  [ ! -f "$cdir/jvm.log" ] || mv -f "$cdir/jvm.log" "$cdir/jvm.log.1"
  nohup clojure -Sdeps "$sdeps" -M:dev:test:testjvm > "$cdir/jvm.log" 2>&1 < /dev/null &
  pid=$!
fi
t0=$SECONDS
until [ -s "$cdir/jvm.pid" ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[testjvm] harness error: the JVM exited during start; the log says:"
    tail -n 30 "$cdir/jvm.log"
    exit 6
  fi
  if [ $(( SECONDS - t0 )) -ge 600 ]; then
    echo "[testjvm] no answer within 600 s; the log says:"
    tail -n 30 "$cdir/jvm.log"
    exit 4
  fi
  sleep 0.2
done
grep -m1 "^\[testjvm\] ready" "$cdir/jvm.log"
'

# Inside the container: TERM the JVM, KILL it after 20 s.
TJ_KILL='
'"$TJ_IN_CTR_LIB"'
pid=$(jvm_pid) || { echo "not running"; exit 0; }
kill "$pid"
for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || { echo "stopped (pid $pid)"; exit 0; }; sleep 0.2; done
kill -9 "$pid"
echo "stopped (pid $pid) with KILL after it ignored TERM for 20 s"
'

testjvm_usage() {
  cat <<'EOF'
pdv testjvm <command> [args…] [--ws N]

A persistent backend test JVM in the instance that serves the caller's
worktree (or the one --ws N names). It keeps the :dev:test classpath loaded,
reloads what changed (clj-reload), and runs kaocha as `--focus` would.

  start              start the JVM, with enable-backend-asserts added to
                     PENPOT_FLAGS as CI does; repairs root-owned storage
                     first and waits until the JVM is ready
  run [--timeout S] [--seed N] [--no-randomize] [id…]
                     reload, then kaocha on the ids: namespaces, vars
                     (ns/test-name), or suite keywords (:unit); none runs
                     the whole suite. No test starts after S seconds
                     (default 1800), counting the wait for the lock. The
                     verdict ends with kaocha's seed; --seed N replays it
  reload             reload only, and print what was reloaded
  cancel             stop the running test run before its next test
  status             pid, uptime, memory, busy state, and staleness
  log [N]            the last N lines of the JVM's output (default 40)
  stop [--force]     stop the JVM; refuses while a run holds it unless --force
  restart [--force]  stop, then start
  repair             give the penpot user back /tmp/penpot and backend/assets
  cold [args…]       a cold `clojure -M:dev:test args…` in backend/, as
                     penpot, with enable-backend-asserts, under the lock

Exit status (run, reload): 0 pass, 1 a test failed or none matched, 2 reload
failed, 3 JVM not running, it died during the call, or no instance serves
the worktree, 4 deadline passed or cancelled, 5 restart needed (for stop
and restart: a run holds the JVM), 6 storage not writable or harness error,
64 bad usage. cold exits with kaocha's status.

Restart after a deps.edn change, after an edit under backend/dev or to a
namespace exempt from reload (app.system, app.common.debug, user), and after
pdv's own share/testjvm.clj changes: run and reload then answer 5.
EOF
}

tj_bad_usage() {
  warn "$1"
  echo "usage: pdv testjvm start | run [--timeout S] [--seed N] [--no-randomize] [id…] | reload | cancel | status | log [N] | stop [--force] | restart [--force] | repair | cold [args…]" >&2
  exit 64
}

# sha256 of pdv's share/testjvm.clj. start hands it to the JVM as
# PENPOT_TESTJVM_SHA, and every guarded call compares it.
testjvm_sha() {
  local sha; sha=$(sha256sum "$PDV_SELF/share/testjvm.clj")
  printf '%s' "${sha%% *}"
}

# Wraps a form for the test JVM in the staleness guard: a JVM started from
# another copy of testjvm.clj answers 5 instead of running old harness code.
# The guard needs nothing from the JVM's own testjvm.clj, and callers reach
# its functions through `resolve`, so the form compiles in a JVM whose copy
# lacks them.
testjvm_guard() {
  printf '(if (= (System/getenv "PENPOT_TESTJVM_SHA") "%s") %s (do (println "[testjvm] restart needed: the test JVM runs an older testjvm.clj") 5))' \
    "$(testjvm_sha)" "$1"
}

# One client call; extra args go to the client.
tj_client() { docker exec -u penpot "$CTR" python3 -S -c "$(nrepl_client_src)" --port "$TJ_PORT" "$@"; }

# Focus ids become Clojure literals: keywords stay keywords, anything else
# is quoted as a symbol. The character check keeps a command-line argument
# from becoming code; an id never starts with a digit or a dash.
tj_focus_forms() {
  local id out=""
  for id in "$@"; do
    case "$id" in
      [0-9-]*|*[!A-Za-z0-9._/*+!?\<\>=:-]*|'')
        warn "not a namespace, var, or suite id: '$id'"; return 1 ;;
      :*) out+=" $id" ;;
      *)  out+=" '$id" ;;
    esac
  done
  printf '%s' "$out"
}

tj_seconds() { case "$2" in ''|0|*[!0-9]*) tj_bad_usage "$1 takes whole seconds above 0" ;; esac; }

# Epoch milliseconds into NOW_MS, without a fork.
tj_now_ms() { local t=${EPOCHREALTIME/./}; NOW_MS=$(( t / 1000 )); }

# Start, stop, and restart take this host lock, one per container: parallel
# callers (agents whose tool found the JVM down) must not launch a second
# JVM or kill the one being started.
tj_start_lock() {
  exec 8>"/tmp/penpot-testjvm-start.$CTR.lock"
  flock -w 620 8 || { warn "another start or stop on $CTR has held the lock for 620 s"; exit 4; }
}

tj_repair() {
  local counts d=0 f=0 o=0 n t
  # shellcheck disable=SC2086 # TJ_STORAGE is two paths
  counts=$(docker exec -u root "$CTR" bash -c "$TJ_REPAIR" repair $TJ_STORAGE)
  while read -r n t; do
    case "$t" in d) d=$n ;; f) f=$n ;; ?) o=$(( o + n )) ;; esac
  done <<< "$counts"
  if [ $(( d + f + o )) = 0 ]; then
    [ "${1:-}" = quiet ] || say "repair: penpot already owns everything under $TJ_STORAGE"
  else
    say "repair: gave penpot back $d directories, $f files, and $o other entries that root owned under $TJ_STORAGE"
  fi
}

tj_start() {
  local out rc
  out=$(docker exec -u penpot "$CTR" bash -c "$TJ_IN_CTR_LIB"'jvm_pid && [ "$(cat '$TJ_CDIR'/jvm.pid 2>/dev/null)" = "$(jvm_pid)" ]')
  if [ $? = 0 ]; then say "already up in $CTR (pid $out); 'restart' replaces it"; return 0; fi
  tj_repair quiet
  say "starting the test JVM in $CTR (log: $TJ_CDIR/jvm.log)"
  why "-M:dev:test keeps :dev's and :test's deps and jvm-opts; the -Sdeps alias adds clj-reload, the heap cap, and a private log4j2 file and, being the last alias with :main-opts, replaces kaocha.runner with testjvm.clj"
  local t0=$SECONDS
  docker exec -u penpot -w "$DEST/backend" \
    -e PENPOT_TESTJVM_SHA="$(testjvm_sha)" -e PENPOT_TESTJVM_WS_FLAG="$WS_FLAG" "$CTR" \
    bash -c "$TJ_LAUNCH" launch "$TJ_CDIR" "$TJ_SDEPS" \
    "$(<"$PDV_SELF/share/testjvm.clj")" "$(<"$PDV_SELF/share/testjvm-log4j2.xml")"
  rc=$?
  case "$rc" in
    0)  say "up after $(( SECONDS - t0 )) s"
        imp "run tests with: pdv testjvm run <ns-or-var>…${WS_FLAG}" ;;
    10) ;;
    *)  return "$rc" ;;
  esac
}

# 5 when a run holds the JVM, printing the holder; 0 otherwise, also when
# the JVM is down or does not answer (stop then has nothing to protect).
tj_busy() {
  tj_client --timeout 5 --exit-value \
    "(if-let [f (resolve 'penpot.testjvm/holder-line)] (if-let [l (f)] (do (println (str \"[testjvm] busy: \" l)) 5) 0) 0)" 2>/dev/null
  [ $? = 5 ] && return 5 || return 0
}

tj_stop() {
  local force=$1
  if ! tj_busy; then
    if [ "$force" != --force ]; then
      imp "stop --force${WS_FLAG} stops it anyway; the run's client then exits 3"
      return 5
    fi
    say "--force: stopping it anyway"
  fi
  say "$(docker exec -u penpot "$CTR" bash -c "$TJ_KILL")"
}

cmd_testjvm() {
  # Every probe reads an exit status, as the in-container scripts return
  # them, so errexit is off for the rest of this verb.
  set +e
  local cmd="${1:-}" timeout=1800 seed=nil randomize=true forms="" rc pid deadline what
  local -a ids=()
  shift || true
  case "$cmd" in
    ''|-h|--help|help) testjvm_usage; exit 0 ;;
    start|reload|cancel|status|repair) [ $# = 0 ] || tj_bad_usage "$cmd takes no arguments" ;;
    stop|restart) case "$#:${1:-}" in 0:|1:--force) ;; *) tj_bad_usage "$cmd takes only --force" ;; esac ;;
    log) [ $# -le 1 ] || tj_bad_usage "log takes one number"
         case "${1:-40}" in 0*|*[!0-9]*) tj_bad_usage "log takes a number of lines above 0" ;; esac ;;
    run)
      while [ $# -gt 0 ]; do
        case "$1" in
          --timeout)      [ $# -ge 2 ] || tj_bad_usage "--timeout needs seconds"; tj_seconds --timeout "$2"; timeout=$2; shift 2 ;;
          --seed)         case "${2:-}" in ''|*[!0-9]*) tj_bad_usage "--seed takes a whole number" ;; esac
                          [ "${#2}" -le 10 ] && [ "$2" -le 2147483647 ] || tj_bad_usage "--seed is at most 2147483647"
                          seed=$(( 10#$2 )); shift 2 ;;
          --no-randomize) randomize=false; shift ;;
          -*)             tj_bad_usage "unknown option '$1'" ;;
          *)              ids+=("$1"); shift ;;
        esac
      done
      [ "$randomize" = true ] || [ "$seed" = nil ] || tj_bad_usage "--seed and --no-randomize exclude each other"
      forms=$(tj_focus_forms ${ids[@]+"${ids[@]}"}) || exit 64
      ;;
    cold) ;;
    *) tj_bad_usage "unknown command '$cmd'" ;;
  esac

  # No instance at all: the JVM is as unreachable as when it is down, so 3.
  select_caller_instance || exit 3

  case "$cmd" in
    start)   tj_start_lock; tj_start; exit $? ;;
    stop)    tj_start_lock; tj_stop "${1:-}"; exit $? ;;
    restart) tj_start_lock; tj_stop "${1:-}" && tj_start; exit $? ;;
    repair)  tj_repair; exit $? ;;
    log)     docker exec "$CTR" tail -n "${1:-40}" "$TJ_CDIR/jvm.log"; exit $? ;;
    cancel)
      tj_client --timeout 10 --exit-value \
        "(if-let [f (resolve 'penpot.testjvm/cancel!)] (f) (do (println \"[testjvm] restart needed: the test JVM runs an older testjvm.clj\") 5))"
      exit $?
      ;;
    status)
      tj_client --timeout 10 \
        "(let [f (resolve 'penpot.testjvm/status-map)] (into (sorted-map :script (if (= (System/getenv \"PENPOT_TESTJVM_SHA\") \"$(testjvm_sha)\") :current :older)) (if f (f) ((resolve 'penpot.testjvm/status)))))"
      rc=$?
      case "$rc" in
        3) if pid=$(docker exec -u penpot "$CTR" bash -c "$TJ_IN_CTR_LIB"'jvm_pid'); then
             say "starting in $CTR (pid $pid, $(docker exec "$CTR" ps -o etimes= -p "$pid" | tr -d ' ') s so far)"
           else
             say "not running in $CTR; start it with: pdv testjvm start${WS_FLAG}"
           fi ;;
        4) say "the JVM accepts connections but does not answer; pdv testjvm restart --force${WS_FLAG}" ;;
      esac
      exit "$rc"
      ;;
    reload)
      tj_now_ms; deadline=$(( NOW_MS + 300000 ))
      docker exec -u penpot "$CTR" bash -c "$TJ_LOCKED" locked $(( deadline / 1000 )) "testjvm reload" "$TJ_MARGIN" \
        python3 -S -c "$(nrepl_client_src)" --port "$TJ_PORT" --exit-value \
        "$(testjvm_guard "((resolve 'penpot.testjvm/reload-cli) {:deadline-ms $deadline})")"
      rc=$?
      [ "$rc" != 3 ] || imp "start it with: pdv testjvm start${WS_FLAG}"
      exit "$rc"
      ;;
    run)
      tj_now_ms; deadline=$(( NOW_MS + timeout * 1000 ))
      what="testjvm run of${forms:- the whole suite}"; what=${what//\'/}
      say "${what#testjvm }"
      docker exec -u penpot "$CTR" bash -c "$TJ_LOCKED" locked $(( deadline / 1000 )) "$what" "$TJ_MARGIN" \
        python3 -S -c "$(nrepl_client_src)" --port "$TJ_PORT" --exit-value \
        "$(testjvm_guard "((resolve 'penpot.testjvm/cli-run) {:deadline-ms $deadline :seed $seed :randomize? $randomize}$forms)")"
      rc=$?
      case "$rc" in
        3) imp "start it with: pdv testjvm start${WS_FLAG}; the log of a JVM that died: pdv testjvm log${WS_FLAG}" ;;
        5) imp "restart it: pdv testjvm restart${WS_FLAG}" ;;
      esac
      exit "$rc"
      ;;
    cold)
      say "cold run: clojure -M:dev:test $* (in $DEST/backend)"
      why "a fresh JVM, as CI runs it, with enable-backend-asserts; under the instance's backend test lock, so it never shares the test database with a test-JVM run"
      tj_now_ms; deadline=$(( NOW_MS / 1000 + 1800 ))
      docker exec -u penpot -w "$DEST/backend" "$CTR" bash -c "$TJ_IN_CTR_LIB$TJ_LOCKED" locked "$deadline" "cold run: clojure -M:dev:test $*" "" \
        clojure -M:dev:test "$@"
      exit $?
      ;;
  esac
}

# -------------------------------------------------------------------- eval
eval_usage() {
  cat <<'EOF'
pdv eval [--target test|backend] [--ns NS] [--timeout S] [--no-reload]
         (<code> | - | --file PATH) [--ws N]

Evaluate Clojure over nREPL in the instance that serves the caller's
worktree (or the one --ws N names).

  <code>             the code, as one argument
  -                  the code from stdin: quotes and newlines need no escaping
  --file PATH        load a host file, which the container need not see, with
                     the nREPL load-file op: errors cite PATH and its lines
  --target test      the test JVM `pdv testjvm` keeps on the :dev:test
                     classpath, isolated from the running system. Reloads
                     the namespaces whose files changed first, unless
                     --no-reload. The default.
  --target backend   the running backend's nREPL (6064): app.system/system and
                     the instance's database. Nothing is reloaded; hot-load an
                     edited file with --file.
  --ns NS            the namespace to evaluate in (default user)
  --timeout S        interrupt the evaluation after S seconds (default 120)

Output streams as the JVM prints it, then each top-level form's value, cut
at 16000 characters. Exit 0 evaluated, 1 the code threw, 2 the reload
failed, 3 the target JVM is not running, it died, or no instance serves the
worktree, 4 no answer within the timeout, 5 the test JVM needs a restart,
6 harness error, 64 bad usage. Write fully qualified names: an alias in
`user` keeps pointing at the namespace object a reload replaced.
EOF
}

eval_bad_usage() {
  warn "$1"
  echo "usage: pdv eval [--target test|backend] [--ns NS] [--timeout SECONDS] [--no-reload] (<code> | - | --file PATH)" >&2
  exit 64
}

cmd_eval() {
  set +e
  local target=test ns="" timeout=120 reload=1 code="" source="" port t guard rc
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)   eval_usage; exit 0 ;;
      --target)    [ $# -ge 2 ] || eval_bad_usage "--target needs test or backend"; target="$2"; shift 2 ;;
      --ns)        [ $# -ge 2 ] || eval_bad_usage "--ns needs a namespace"; ns="$2"; shift 2 ;;
      --timeout)   [ $# -ge 2 ] || eval_bad_usage "--timeout needs seconds"; timeout="$2"; shift 2 ;;
      --no-reload) reload=0; shift ;;
      --file)      [ $# -ge 2 ] || eval_bad_usage "--file needs a path"
                   [ -z "$source" ] || eval_bad_usage "one of <code>, -, or --file"
                   source=file code="$2"; shift 2 ;;
      -)           [ -z "$source" ] || eval_bad_usage "one of <code>, -, or --file"
                   source=stdin; shift ;;
      *)           [ -z "$source" ] || eval_bad_usage "one code argument only; quote it, or pass - and the code on stdin"
                   source=arg code="$1"; shift ;;
    esac
  done
  [ -n "$source" ] || eval_bad_usage "no code to evaluate"
  [ "$source" != arg ] || [ -n "$code" ] || eval_bad_usage "no code to evaluate"
  case "$timeout" in ''|0|*[!0-9]*) eval_bad_usage "--timeout takes whole seconds above 0" ;; esac
  case "$target" in
    test)    port=6065 ;;
    backend) port=6064 ;;
    *)       eval_bad_usage "--target is test or backend, not '$target'" ;;
  esac
  if [ "$source" = file ]; then
    # A relative path names a file under the caller's directory, not the
    # checkout pdv changed into.
    case "$code" in /*) ;; *) code="$CALLER_DIR/$code" ;; esac
    [ -f "$code" ] && [ -r "$code" ] || eval_bad_usage "--file: cannot read '$code'"
    code=$(readlink -f "$code")
  fi

  select_caller_instance || exit 3

  local -a args=(--port "$port" --timeout "$timeout")
  [ -z "$ns" ] || args+=(--ns "$ns")
  if [ "$target" = test ]; then
    # The reload, or with --no-reload only the activity mark for the idle
    # exit, runs first on the client's connection; the code runs only when
    # it returns 0. The reload waits for a test run until the timeout.
    t=${EPOCHREALTIME/./}
    if [ "$reload" = 1 ]; then
      guard="((resolve 'penpot.testjvm/reload-cli) {:deadline-ms $(( t / 1000 + timeout * 1000 )) :quiet? true})"
    else
      guard="((resolve 'penpot.testjvm/touch!))"
    fi
    args+=(--pre "$(testjvm_guard "$guard")")
  fi

  # The client's source travels as an argument, so stdin is free for code.
  local src
  src=$(nrepl_client_src)
  case "$source" in
    file)  docker exec -i -u penpot "$CTR" python3 -S -c "$src" "${args[@]}" \
             --load-file "$code" --file-name "${code##*/}" < "$code" ;;
    stdin) docker exec -i -u penpot "$CTR" python3 -S -c "$src" "${args[@]}" - ;;
    arg)   docker exec -u penpot "$CTR" python3 -S -c "$src" "${args[@]}" -- "$code" ;;
  esac
  rc=$?

  case "$rc:$target" in
    3:test)    imp "start the test JVM with: pdv testjvm start${WS_FLAG}" ;;
    3:backend) imp "is the backend running? pdv status${WS_FLAG}" ;;
    5:test)    imp "restart it: pdv testjvm restart${WS_FLAG}" ;;
  esac
  exit "$rc"
}

# -------------------------------------------------------------------- repl
# Host editors reach the backend's nREPL through a bridge: the host cannot
# route to the container and no nREPL port is published. The backend's own
# server (6064, from app.main) has only the default handler, so a second
# server with the cider-nrepl middleware is started on 6066 in the same JVM:
# Clojure 1.12's add-lib fetches the jar into the running JVM and the
# backend's deps stay untouched. CIDER_NREPL_VERSION picks the release (an
# editor passes the one its CIDER expects); the first version loaded stays
# for the JVM's life, because add-lib skips a lib already on the classpath.
# The host port is 6064 for ws0 and +N*10000 for wsN, manage.sh's rule for
# published ports, so bridges to several instances coexist. The last starter
# wins: a bridge already holding the port, which is always one onto the same
# instance, is replaced.
REPL_PORT=6064
REPL_CIDER_PORT=6066          # 6065 is the test JVM's

repl_up() {
  docker exec "$CTR" bash -c "exec 3<>/dev/tcp/127.0.0.1/${1:-$REPL_PORT}" 2>/dev/null
}

cmd_repl() {
  [ "${#REST[@]}" -eq 0 ] || svc_usage "repl: unexpected argument '${REST[0]}' (repl takes only --ws N)"
  command -v python3 >/dev/null || die "repl: the host bridge needs python3 on the host"
  select_caller_instance || exit 3
  local version="${CIDER_NREPL_VERSION:-0.62.2}" listen target=$REPL_PORT pid desc
  listen=$(( REPL_PORT + WS_INDEX * 10000 ))

  if repl_up; then
    say "repl: nREPL listening on :$REPL_PORT in $CTR"
  else
    # start-dev opens 6064 itself. A busy backend pane without the port is
    # the interactive console (scripts/repl), which can start a server.
    pid=$(tmx list-panes -t "$SESSION:backend" -F '#{pane_pid}' 2>/dev/null | head -1 || true)
    if [ -n "$pid" ] && desc=$(pane_busy "$pid"); then
      say "repl: nREPL is down on :$REPL_PORT; starting one from the backend window ('$(printf '%.40s' "$desc")')"
      tmx send-keys -t "$SESSION:backend" \
        "(do (require (quote nrepl.server)) (nrepl.server/start-server :bind \"0.0.0.0\" :port $REPL_PORT))" Enter
      for _ in $(seq 1 10); do repl_up && break; sleep 1; done
    fi
    repl_up || die "repl: no nREPL on :$REPL_PORT in $CTR; start the backend with: pdv start --services backend${WS_FLAG}"
  fi

  # The cider server lives in the backend JVM, so a backend restart takes it
  # down and the next `pdv repl` brings it back.
  if repl_up "$REPL_CIDER_PORT"; then
    say "repl: cider-nrepl listening on :$REPL_CIDER_PORT in $CTR"
    target=$REPL_CIDER_PORT
  else
    say "repl: starting cider-nrepl $version on :$REPL_CIDER_PORT in $CTR"
    why "the backend's own server lacks the middleware an editor needs to find definitions, show docs, and debug; the first fetch takes about 10 s"
    docker exec -i -u penpot "$CTR" python3 -S -c "$(nrepl_client_src)" --port "$REPL_PORT" --timeout 180 - <<EOF || true
(do (require 'clojure.repl.deps)
    ((resolve 'clojure.repl.deps/add-lib) 'cider/cider-nrepl {:mvn/version "$version"})
    (require 'cider.nrepl)
    (nrepl.server/start-server :bind "127.0.0.1" :port $REPL_CIDER_PORT
                               :handler @(resolve 'cider.nrepl/cider-nrepl-handler))
    :started)
EOF
    if repl_up "$REPL_CIDER_PORT"; then
      target=$REPL_CIDER_PORT
    else
      warn "repl: cider-nrepl did not start; bridging the plain nREPL on :$REPL_PORT"
    fi
  fi

  # Editors that read .nrepl-port (Zed's tasks, CIDER) find the bridge there.
  if printf '%s\n' "$listen" >"$HOST_ROOT/.nrepl-port" 2>/dev/null; then
    say "repl: wrote $HOST_ROOT/.nrepl-port ($listen)"
  else
    warn "repl: could not write $HOST_ROOT/.nrepl-port"
  fi

  if pkill -f "repl-bridge.py .*--listen-port $listen( |$)" 2>/dev/null; then
    say "repl: replaced the bridge that held :$listen"
    for _ in $(seq 1 10); do
      python3 -c "import socket,sys;s=socket.socket();sys.exit(0 if s.connect_ex(('127.0.0.1',$listen)) else 1)" && break
      sleep 0.3
    done
  fi

  say "repl: bridge on 127.0.0.1:$listen -> $CTR:$target (Ctrl-C stops it)"
  exec python3 "$PDV_SELF/lib/repl-bridge.py" --container "$CTR" --listen-port "$listen" --target-port "$target"
}

# --------------------------------------------------------------------- lsp
# An editor runs `pdv lsp` as its clojure-lsp binary: stdin and stdout carry
# the LSP stream to a clojure-lsp inside the instance, which has the full
# classpath (.m2, .gitlibs). share/lsp-bridge.py runs in the container and
# rewrites paths between the host tree and the bind mount. One editor
# session is one `docker exec` and one clojure-lsp. Stdout belongs to the
# protocol, so every message here goes to stderr.
cmd_lsp() {
  [ "${#REST[@]}" -eq 0 ] || svc_usage "lsp: unexpected argument '${REST[0]}' (lsp takes only --ws N)"
  select_caller_instance >&2 || exit 3
  # The image ships no clojure-lsp. Serena downloads one into the
  # container home, which survives a recreate; a clojure-lsp on PATH wins.
  local bin real
  bin=$(docker exec -u penpot "$CTR" bash -c '
    command -v clojure-lsp && exit 0
    f=$HOME/.serena/language_servers/static/ClojureLSP/clojure-lsp
    [ -x "$f" ] && echo "$f"' 2>/dev/null || true)
  if [ -z "$bin" ]; then
    warn "lsp: $CTR has no clojure-lsp: none on PATH, and Serena has not downloaded one into ~/.serena yet"
    warn "lsp: bring the instance up with --agentic once (Serena fetches it), or install clojure-lsp in the container home"
    exit 1
  fi
  local -a hosts=()
  real=$(readlink -f "$HOST_ROOT")
  hosts=("$real")
  [ "$HOST_ROOT" = "$real" ] || hosts+=("$HOST_ROOT")
  exec docker exec -i -u penpot "$CTR" python3 -c "$(<"$PDV_SELF/share/lsp-bridge.py")" "$bin" "${hosts[@]}"
}

# -------------------------------------------------------------------- jobs
# The job table records every background job the backend runs (webhook
# events, delete-object, GC). When a save seems to vanish, or the backend
# pane looks quiet, it answers "did the work arrive and finish" without
# reading pane logs. The table lives in the database the backend uses, and
# the instance's tenant (PENPOT_TENANT, devenv-wsN) filters it.
cmd_jobs() {
  local n=15 a
  for a in ${REST[@]+"${REST[@]}"}; do
    case "$a" in
      ''|*[!0-9]*) echo "usage: pdv jobs [count] (default 15)" >&2; exit 2 ;;
      *) n="$a" ;;
    esac
  done
  select_caller_instance || exit 3
  manage_load
  instance_job_target
  say "jobs for $JOB_TENANT in $JOB_DB, newest first (last $n)"
  why "the database is the one the backend uses, and the tenant names this instance's rows"
  seed_pg_container >/dev/null || die "jobs: the shared postgres container is not running"
  seed_psql "$JOB_DB" -P tuples_only=off -P format=aligned -P footer=off -c "
      SELECT to_char(created_at, 'HH24:MI:SS') AS at, name, status,
             left(coalesce(error::text, ''), 60) AS error
      FROM job WHERE tenant = '$JOB_TENANT'
      ORDER BY created_at DESC LIMIT $n" \
    || die "jobs: the query failed; the job table's schema may have moved upstream"
}

# The database and tenant of the selected instance's job rows: the database
# the live backend uses, else the worktree's remembered one, else
# pdvwt_<slug>, and the container's PENPOT_TENANT. Sets JOB_DB and JOB_TENANT.
instance_job_target() {
  local tree
  tree=$(readlink -f "$HOST_ROOT")
  JOB_DB=$(seed_live_backend_db)
  if [ -z "$JOB_DB" ]; then
    JOB_DB=$(seed_state_read "$tree" pdv-db)
    [ -n "$JOB_DB" ] || JOB_DB=$(seed_db_for_tree "$tree")
  fi
  JOB_TENANT=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CTR" 2>/dev/null \
                 | sed -n 's/^PENPOT_TENANT=//p' | head -1)
  JOB_TENANT="${JOB_TENANT:-devenv-$WS}"
}

# ---------------------------------------------------------- build-frontend
# The release build for a UI that runs with no watcher (see the watcher modes
# in lib/pdv-services.sh). The build wipes frontend/node_modules and
# resources/public, which a live watcher reads and writes, so a running
# frontend or storybook watcher is refused with exit 3, or stopped after a
# confirmation on a terminal. frontend_build checks again, so a watcher that
# survived the stop also blocks the build.
cmd_build_frontend() {
  [ "${#REST[@]}" -eq 0 ] || svc_usage "build-frontend: unexpected argument '${REST[0]}' (build-frontend takes only --ws N)"
  select_caller_instance || exit 3
  local svc ans
  local -a busy=()
  read -ra busy <<<"$(busy_frontend_watchers)"
  if [ "${#busy[@]}" -gt 0 ]; then
    say "build-frontend: a watcher runs in $CTR (services: ${busy[*]})"
    why "the build wipes frontend/node_modules and frontend/resources/public, which a live watcher reads and writes"
    if [ ! -t 0 ]; then
      warn "build-frontend: nothing built; stop the watchers first with: pdv stop --watchers --ws $WS_INDEX --build"
      exit 3
    fi
    read -r -p "[pdv] stop those watchers and build? [y/N] " ans
    if [ "${ans,,}" != y ]; then
      warn "build-frontend: nothing built; the watchers keep running"
      exit 3
    fi
    say "build-frontend: stopping the ${busy[*]} watcher windows before the build"
    for svc in "${busy[@]}"; do stop_service "$svc"; done
  fi
  local rc=0
  frontend_build || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  say "UI now: $(ui_url)  ($(bundle_state_text "$(frontend_bundle_state "$HOST_ROOT")"); hard-reload open tabs)"
  sub "next frontend change: pdv build-frontend --ws $WS_INDEX, or back to watching: pdv start --watchers --ws $WS_INDEX"
}

# -------------------------------------------------------------- bug-report
# The checklist to hand to whoever reports a devenv bug. Items 4, 5, and 6
# usually settle it: a websocket-level frontend exception shows the failing
# frame, a backend exception shows the stacktrace, and the job table says
# whether the work arrived. Best effort, because a checklist is most needed
# when the instance is down: with no instance to name, the template carries
# placeholders, and every command in it is portable to any checkout with pdv
# installed. The postgres container name is fixed by manage.sh's compose
# project, penpotdev-infra.
cmd_bug_report() {
  [ "${#REST[@]}" -eq 0 ] || svc_usage "bug-report: unexpected argument '${REST[0]}' (bug-report takes only --ws N)"
  local ctr="penpot-devenv-wsN-main" tenant="devenv-wsN" db="pdvwt_<worktree slug>" ws="N"
  if select_caller_instance 2>/dev/null; then
    instance_job_target
    ctr=$CTR tenant=$JOB_TENANT db=$JOB_DB ws=$WS_INDEX
  elif $WS_GIVEN; then
    ctr=$CTR tenant="devenv-$WS" ws=$WS_INDEX
    say "$CTR is not running; its database is a placeholder"
  else
    say "no running instance serves this worktree; the checklist carries placeholders"
  fi
  say "checklist for a devenv bug report: paste it to the reporter; items 4, 5, and 6 usually settle it"
  cat <<EOF

  1. CODE AND INSTANCE, in the checkout the bug ran on:
       git status -sb && git rev-parse HEAD
     when the instance was last started or refreshed, and all the output of:
       pdv status --ws ${ws}
  2. EXACT STEPS: the file (name and id), new or existing, branched or
     not, which shape type was edited, one editor or several, and what
     "save" meant for them: autosave, Ctrl+S, page switch, tab close.
  3. THE VISIBLE ERROR: screenshot of the toast, with its text.
  4. DEVTOOLS CONSOLE at the moment of failure. Saves go over the
     websocket, so a Network-tab capture may show nothing: right-click
     the \`ws\` connection, open Messages, capture the frames around
     the failure.
  5. BACKEND PANE, around the failure timestamp:
       docker exec -u penpot ${ctr} tmux capture-pane -p -t penpot:backend -S -400
     Exceptions print as E lines with a SUMMARY/DETAIL stacktrace.
  6. WHEN A SAVE SEEMS TO VANISH, or the pane looks quiet, the job table:
       pdv jobs --ws ${ws}
     or, without pdv:
       docker exec penpotdev-infra-postgres-1 psql -U penpot -d ${db} -At -c \\
         "SELECT name, status, to_char(created_at,'HH24:MI:SS') FROM job \\
          WHERE tenant='${tenant}' ORDER BY created_at DESC LIMIT 10"
     A save leaves a process-webhook-event row that reaches completed
     seconds later; a failed row carries its error.
  7. TIMESTAMP with timezone, to correlate the captures above.
  8. SCOPE: does it also fail on a brand-new file, on other files,
     after an instance restart?

  Never paste cookies or tokens; screenshots and log excerpts are fine.

  Every command above runs in any Penpot checkout: the pdv lines need
  only pdv installed (https://github.com/alvorithm/pdv), and the git,
  docker, and psql lines need nothing else.
EOF
}
