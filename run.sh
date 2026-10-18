#!/usr/bin/env bash
# =============================================================================
# DevOps Task Manager launcher
#
#   ./run.sh start | stop | restart | status | logs | check | verify | deploy | help
#
# Design rules
#   * MongoDB is only reachable on the internal Docker network
#     (mongodb://mongo:27017/devops_tasks), so it never fights for host port 27017.
#     Host ports are configurable: API_HOST_PORT (default 5000); MONGO_HOST_PORT
#     (default 27017) only matters with --expose-db.
#   * Nothing unrelated is ever stopped, killed or removed. Volumes and database
#     data are never deleted by this script (there is no `down -v` anywhere).
#   * Every external call is bounded by a timeout; success is only reported after
#     the API answered /health with "database":"connected".
# =============================================================================
set -Eeuo pipefail
umask 077

# ----------------------------------------------------------------------------
# Constants / tunables (override with environment variables)
# ----------------------------------------------------------------------------
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT
readonly APP_ID="devops-task-manager"        # compose project, k8s namespace, /health "service"
readonly K8S_DIR="$ROOT/k8s"
readonly K8S_IMAGE_LOCAL="devops-task-manager:1.0"   # image referenced by k8s/api-deployment.yaml
readonly LOG_DIR="${TM_LOG_DIR:-$ROOT/logs}"
readonly RUN_DIR="${TM_RUN_DIR:-$ROOT/.run}"
readonly LAUNCH_LOG="$LOG_DIR/launcher.log"

BUILD_TIMEOUT="${TM_BUILD_TIMEOUT:-600}"     # docker compose build/up (seconds)
START_TIMEOUT="${TM_START_TIMEOUT:-120}"     # wait for API + MongoDB to become healthy
STOP_TIMEOUT="${TM_STOP_TIMEOUT:-60}"
ROLLOUT_TIMEOUT="${TM_ROLLOUT_TIMEOUT:-300}" # kubectl rollout status
CALL_TIMEOUT="${TM_CALL_TIMEOUT:-15}"        # single docker/kubectl/gh query

# Exit codes
readonly E_FAIL=1 E_USAGE=2 E_NOTRUNNING=3 E_UNHEALTHY=4
readonly E_TOOL=10 E_CONFIG=11 E_PORT=20 E_DOCKER=24 E_BUILD=25 E_TIMEOUT=30 E_K8S=40 E_LOCK=34

# Options
EXPOSE_DB="${TM_EXPOSE_DB:-0}"
REMOVE_CONTAINERS=0
FOLLOW=0
TAIL_LINES=100
SMOKE=0
ALLOW_CONTEXT="${TM_K8S_ALLOW_CONTEXT:-0}"
TARGET=""
POSITIONAL=()

# Result tracking for the final summary
N_OK=0 N_WARN=0 N_FAIL=0
SUMMARY=()
COMPOSE=()
API_PORT="" MONGO_PORT=""
TMP_FILES=()

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
  C_R=$'\e[0m' C_G=$'\e[32m' C_Y=$'\e[33m' C_RED=$'\e[31m' C_B=$'\e[36m'
else
  C_R="" C_G="" C_Y="" C_RED="" C_B=""
fi

mask() { sed -E 's#(://)[^/@[:space:]]+@#\1***@#g' <<<"$*"; }
_log() { { printf '%s %-5s %s\n' "$(date '+%F %T')" "$1" "$(mask "$2")" >>"$LAUNCH_LOG"; } 2>/dev/null || true; }
sep()   { printf '%s\n' "------------------------------------------------------------"; }
title() { printf '\n'; sep; printf '%s\n' "$*"; sep; }
info()  { printf '%sINFO %s %s\n'  "$C_B" "$C_R" "$(mask "$*")"; _log INFO "$*"; }
ok()    { printf '%sOK   %s %s\n'  "$C_G" "$C_R" "$(mask "$*")"; _log OK "$*"; N_OK=$((N_OK + 1)); SUMMARY+=("OK    $(mask "$*")"); }
warn()  { printf '%sWARN %s %s\n'  "$C_Y" "$C_R" "$(mask "$*")" >&2; _log WARN "$*"; N_WARN=$((N_WARN + 1)); SUMMARY+=("WARN  $(mask "$*")"); }
err()   { printf '%sERROR%s %s\n'  "$C_RED" "$C_R" "$(mask "$*")" >&2; _log ERROR "$*"; N_FAIL=$((N_FAIL + 1)); SUMMARY+=("FAIL  $(mask "$*")"); }
hint()  { printf '      -> %s\n' "$(mask "$*")" >&2; }

cleanup() { local f; for f in "${TMP_FILES[@]:-}"; do [[ -n $f ]] && rm -f -- "$f"; done; return 0; }
trap cleanup EXIT

# print_summary RESULT_LABEL
print_summary() {
  title "SUMMARY"
  local l
  for l in "${SUMMARY[@]:-}"; do [[ -n $l ]] && printf '  %s\n' "$l"; done
  sep
  printf '  %s ok, %s warnings, %s failures   (log: %s)\n' "$N_OK" "$N_WARN" "$N_FAIL" "$LAUNCH_LOG"
  printf '  RESULT: %s\n' "$1"
  sep
}

# die CODE "message" ["hint" ...]  -> error, summary, exit CODE. Never reports success.
die() {
  local code=$1 msg=$2; shift 2
  err "$msg"
  local h; for h in "$@"; do [[ -n $h ]] && hint "$h"; done
  print_summary "FAILED (exit $code)"
  exit "$code"
}

is_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

# ----------------------------------------------------------------------------
# Config (read .env as data - it is never sourced or executed)
# ----------------------------------------------------------------------------
dotenv_get() { # KEY -> value of the last KEY=... line in .env (quotes and CR stripped)
  local f="$ROOT/.env" v=""
  [[ -r $f ]] || return 0
  v=$(grep -E "^[[:space:]]*${1}=" "$f" | tail -n1 | sed -E "s/^[^=]*=//; s/\r$//; s/^[\"']//; s/[\"']$//" || true)
  printf '%s' "$v"
}

load_config() {
  API_PORT="${API_HOST_PORT:-$(dotenv_get API_HOST_PORT)}"; API_PORT="${API_PORT:-5000}"
  MONGO_PORT="${MONGO_HOST_PORT:-$(dotenv_get MONGO_HOST_PORT)}"; MONGO_PORT="${MONGO_PORT:-27017}"
  is_port "$API_PORT"   || die $E_CONFIG "API_HOST_PORT='$API_PORT' is not a valid port (1-65535)." "Set API_HOST_PORT=5001 in .env or the environment."
  is_port "$MONGO_PORT" || die $E_CONFIG "MONGO_HOST_PORT='$MONGO_PORT' is not a valid port (1-65535)." "Set MONGO_HOST_PORT=27018 in .env or the environment."
  API_PORT=$((10#$API_PORT)); MONGO_PORT=$((10#$MONGO_PORT))
  export API_HOST_PORT="$API_PORT" MONGO_HOST_PORT="$MONGO_PORT"
}

# ----------------------------------------------------------------------------
# Environment helpers
# ----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
need_tool() { have "$1" || die $E_TOOL "Required command not found: $1" "$2"; }

ensure_dirs() {
  mkdir -p -- "$LOG_DIR" "$RUN_DIR" 2>/dev/null || {
    err "Cannot create $LOG_DIR / $RUN_DIR"; hint "Fix permissions or set TM_LOG_DIR / TM_RUN_DIR."; exit $E_CONFIG; }
  [[ -w $LOG_DIR && -w $RUN_DIR ]] || { err "Log/run directories are not writable."; exit $E_CONFIG; }
  # keep the launcher log small
  if [[ -f $LAUNCH_LOG ]] && (( $(stat -c %s -- "$LAUNCH_LOG" 2>/dev/null || echo 0) > 2097152 )); then
    mv -f -- "$LAUNCH_LOG" "$LAUNCH_LOG.1"
  fi
}

acquire_lock() { # serialise start/stop/deploy; harmless if flock is missing
  have flock || return 0
  exec 9>"$RUN_DIR/run.lock"
  flock -w 10 9 || die $E_LOCK "Another ./run.sh is already starting/stopping the project." "Wait for it to finish and retry."
}

release_lock() {
  if have flock; then flock -u 9 2>/dev/null || true; exec 9>&-; fi
  return 0
}

docker_ready() { # sets COMPOSE; dies with a precise reason
  need_tool docker "Install Docker Engine / Docker Desktop: https://docs.docker.com/engine/install/"
  local out
  if ! out=$(timeout "$CALL_TIMEOUT" docker info 2>&1 >/dev/null); then
    if [[ $out == *"permission denied"* ]]; then
      die $E_DOCKER "Permission denied talking to the Docker daemon." "Add your user to the docker group: sudo usermod -aG docker \"\$USER\" (then log out/in)."
    fi
    die $E_DOCKER "Docker daemon is not reachable." "Start it: sudo systemctl start docker (Linux) or open Docker Desktop (Windows/macOS)."
  fi
  if timeout "$CALL_TIMEOUT" docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif have docker-compose; then
    COMPOSE=(docker-compose)
  else
    die $E_DOCKER "Docker Compose is not installed." "Install the compose plugin: https://docs.docker.com/compose/install/"
  fi
  COMPOSE+=(-p "$APP_ID" -f "$ROOT/docker-compose.yml")
  if [[ $EXPOSE_DB == 1 ]]; then COMPOSE+=(-f "$ROOT/docker-compose.dev.yml"); fi
}

compose() { timeout "$CALL_TIMEOUT" "${COMPOSE[@]}" "$@" 9>&-; }

port_listening() { # any listener on TCP port $1 (IPv4 or IPv6)
  if have ss; then
    [[ -n $(ss -H -ltn "sport = :$1" 2>/dev/null) ]]
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

port_publisher() { # name of a Docker container publishing host port $1 (any project)
  timeout "$CALL_TIMEOUT" docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null | head -n1 || true
}

service_cid() { compose ps -q "$1" 2>/dev/null | head -n1 || true; }

container_status() { # running|exited|restarting|... or "missing"
  local cid=$1
  [[ -n $cid ]] || { printf 'missing'; return 0; }
  timeout "$CALL_TIMEOUT" docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || printf 'missing'
}

container_health() { # healthy|unhealthy|starting|none
  timeout "$CALL_TIMEOUT" docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || printf 'none'
}

api_health() { curl -fsS --max-time 3 "http://127.0.0.1:$1/health" 2>/dev/null || true; }

# our own stack already publishes this host port?
stack_owns_port() { # service port
  local cid; cid=$(service_cid "$1")
  [[ -n $cid && $(container_status "$cid") == running ]]
}

warn_legacy_volumes() { # data from older compose runs lives in differently named volumes; never touched
  local v
  while IFS= read -r v; do
    [[ -n $v && $v != "${APP_ID}_mongo_data" ]] || continue
    warn "Found another MongoDB volume '$v' (older run?). It is NOT used and NOT modified."
    hint "Your old tasks, if any, are in it. To inspect: docker run --rm -v $v:/d alpine ls /d"
  done < <(timeout "$CALL_TIMEOUT" docker volume ls -q --filter name=mongo_data 2>/dev/null || true)
}

# ----------------------------------------------------------------------------
# Docker: start / stop / status / logs
# ----------------------------------------------------------------------------
preflight_docker() {
  [[ -f $ROOT/docker-compose.yml && -f $ROOT/Dockerfile ]] || die $E_CONFIG "docker-compose.yml or Dockerfile missing in $ROOT." "Run ./run.sh from the project root."
  need_tool curl "sudo apt install curl"
  docker_ready
  local out
  out=$(timeout "$CALL_TIMEOUT" "${COMPOSE[@]}" config --quiet 2>&1) || die $E_CONFIG "docker-compose.yml is invalid: $(head -n1 <<<"$out")" "Run: docker compose config"
  ok "Docker daemon and Compose are usable; docker-compose.yml is valid"
}

check_ports() {
  local owner
  if stack_owns_port api; then
    ok "Host port $API_PORT is already served by this project's API (re-use)"
  elif port_listening "$API_PORT"; then
    owner=$(port_publisher "$API_PORT")
    die $E_PORT "Host port $API_PORT is already in use${owner:+ by container \"$owner\"}." \
      "Nothing was stopped. Pick another port: API_HOST_PORT=$((API_PORT + 1)) ./run.sh start" \
      "${owner:+To free it yourself: docker stop $owner}" "See what listens: ss -ltnp 'sport = :$API_PORT'"
  else
    ok "Host port $API_PORT is free"
  fi
  if [[ $EXPOSE_DB == 1 ]]; then
    if stack_owns_port mongo && [[ -n $(timeout "$CALL_TIMEOUT" docker port "$(service_cid mongo)" 27017 2>/dev/null) ]]; then
      ok "Host port $MONGO_PORT is already published by this project's MongoDB (re-use)"
    elif port_listening "$MONGO_PORT"; then
      owner=$(port_publisher "$MONGO_PORT")
      die $E_PORT "Host port $MONGO_PORT (MongoDB) is already in use${owner:+ by container \"$owner\"}." \
        "Use another one: MONGO_HOST_PORT=$((MONGO_PORT + 1)) ./run.sh start --expose-db" \
        "Or skip --expose-db: the API reaches MongoDB internally and needs no host port."
    else
      ok "Host port $MONGO_PORT is free (MongoDB, --expose-db)"
    fi
  else
    info "MongoDB is not published on the host (internal network only) - no 27017 conflict possible"
  fi
}

wait_stack_healthy() { # bounded; dies on crash/timeout
  local deadline=$((SECONDS + START_TIMEOUT)) delay=1 body="" mcid acid mst="" ast="" mh=none
  info "Waiting up to ${START_TIMEOUT}s for MongoDB and the API to become healthy..."
  while (( SECONDS < deadline )); do
    mcid=$(service_cid mongo); acid=$(service_cid api)
    mst=$(container_status "$mcid"); ast=$(container_status "$acid")
    if [[ $mst == exited || $mst == dead ]]; then stack_failure "MongoDB container stopped unexpectedly" mongo; fi
    if [[ $ast == exited || $ast == dead ]]; then stack_failure "API container stopped unexpectedly" api; fi
    [[ $mst == running ]] && mh=$(container_health "$mcid")
    body=$(api_health "$API_PORT")
    if [[ $body == *"\"service\":\"$APP_ID\""* && $body == *'"database":"connected"'* ]]; then
      ok "MongoDB is $mh and the API reports database=connected"
      return 0
    fi
    sleep "$delay"; delay=$(( delay < 3 ? delay + 1 : 3 ))
  done
  stack_failure "Stack not healthy after ${START_TIMEOUT}s (mongo=$mst/$mh, api=$ast, health=${body:-no response})" api
}

stack_failure() { # message service  (exits)
  err "$1"
  compose ps -a >&2 || true
  printf '      --- last %s log lines (%s) ---\n' 25 "$2" >&2
  timeout "$CALL_TIMEOUT" "${COMPOSE[@]}" logs --no-color --tail 25 "$2" 2>&1 | sed -E 's#(://)[^/@ ]+@#\1***@#g; s/^/      | /' >&2 || true
  hint "Partial deployment left in place for inspection (data volume untouched). Retry: ./run.sh start   Remove containers only: ./run.sh stop --remove"
  print_summary "FAILED (exit $E_TIMEOUT)"
  exit $E_TIMEOUT
}

print_urls() {
  printf '\n  Web UI : http://localhost:%s\n  API    : http://localhost:%s/api\n  Health : http://localhost:%s/health\n' "$API_PORT" "$API_PORT" "$API_PORT"
  printf '  MongoDB: mongodb://mongo:27017/devops_tasks (internal network only%s)\n' \
    "$([[ $EXPOSE_DB == 1 ]] && printf '; host: 127.0.0.1:%s' "$MONGO_PORT")"
}

cmd_start() {
  title "START: Docker Compose stack"
  ensure_dirs; load_config; acquire_lock
  preflight_docker
  check_ports
  warn_legacy_volumes
  info "Building image and starting containers (timeout ${BUILD_TIMEOUT}s; log: $LOG_DIR/compose-up.log)..."
  local rc=0
  timeout "$BUILD_TIMEOUT" "${COMPOSE[@]}" up -d --build >"$LOG_DIR/compose-up.log" 2>&1 9>&- || rc=$?
  if (( rc != 0 )); then
    err "docker compose up failed (exit $rc)$([[ $rc == 124 ]] && printf ' - timed out after %ss' "$BUILD_TIMEOUT")"
    sed -E 's#(://)[^/@ ]+@#\1***@#g; s/^/      | /' < <(tail -n 25 "$LOG_DIR/compose-up.log") >&2
    hint "Fix the error above and rerun ./run.sh start. Existing containers and the MongoDB volume were not removed."
    print_summary "FAILED (exit $E_BUILD)"; exit $E_BUILD
  fi
  ok "Containers created/updated"
  wait_stack_healthy
  print_urls
  print_summary "SUCCESS"
}

cmd_stop() {
  title "STOP: Docker Compose stack"
  ensure_dirs; load_config; acquire_lock
  docker_ready
  if [[ -z $(timeout "$CALL_TIMEOUT" "${COMPOSE[@]}" ps -aq 2>/dev/null) ]]; then
    ok "Nothing to stop: no containers exist for project '$APP_ID'"
    print_summary "SUCCESS"; return 0
  fi
  if (( REMOVE_CONTAINERS )); then
    info "Removing containers and network (volumes are kept)..."
    timeout "$STOP_TIMEOUT" "${COMPOSE[@]}" down --timeout 20 >>"$LAUNCH_LOG" 2>&1 9>&- \
      || die $E_FAIL "docker compose down failed or timed out." "See $LAUNCH_LOG; run: docker compose -p $APP_ID ps -a"
    ok "Containers removed; MongoDB data volume '${APP_ID}_mongo_data' kept"
  else
    info "Stopping containers (kept, with their data)..."
    timeout "$STOP_TIMEOUT" "${COMPOSE[@]}" stop --timeout 20 >>"$LAUNCH_LOG" 2>&1 9>&- \
      || die $E_FAIL "docker compose stop failed or timed out." "Run: docker compose -p $APP_ID ps -a"
    ok "Containers stopped; data kept"
  fi
  print_summary "SUCCESS"
}

cmd_restart() { cmd_stop >/dev/null || true; N_OK=0 N_WARN=0 N_FAIL=0; SUMMARY=(); cmd_start; }

cmd_status() {
  title "STATUS"
  ensure_dirs; load_config; docker_ready
  compose ps -a || true
  local acid ast body
  acid=$(service_cid api); ast=$(container_status "$acid")
  if [[ $ast == missing ]]; then
    err "API container does not exist (not started)"; hint "Run: ./run.sh start"
    print_summary "NOT RUNNING"; exit $E_NOTRUNNING
  fi
  [[ $ast == running ]] || { err "API container state: $ast"; print_summary "NOT RUNNING"; exit $E_NOTRUNNING; }
  body=$(api_health "$API_PORT")
  if [[ $body == *"\"service\":\"$APP_ID\""* && $body == *'"database":"connected"'* ]]; then
    ok "API healthy on port $API_PORT, database connected"
    print_urls; print_summary "RUNNING"; return 0
  fi
  err "API container is running but /health on port $API_PORT says: ${body:-no response}"
  hint "Check logs: ./run.sh logs api"
  print_summary "UNHEALTHY"; exit $E_UNHEALTHY
}

cmd_logs() {
  ensure_dirs; load_config
  local svc="${POSITIONAL[0]:-}"
  if [[ $svc == launcher ]]; then tail -n "$TAIL_LINES" "$LAUNCH_LOG" 2>/dev/null || info "No launcher log yet."; return 0; fi
  case $svc in ""|api|mongo) ;; *) die $E_USAGE "Unknown log target '$svc'." "Use: ./run.sh logs [api|mongo|launcher] [-f] [-n N]";; esac
  docker_ready
  if (( FOLLOW )); then
    info "Following logs (Ctrl+C to stop)..."
    exec "${COMPOSE[@]}" logs --no-color --tail "$TAIL_LINES" -f ${svc:+"$svc"}
  fi
  timeout 30 "${COMPOSE[@]}" logs --no-color --tail "$TAIL_LINES" ${svc:+"$svc"} 2>&1 | sed -E 's#(://)[^/@ ]+@#\1***@#g'
}

# ----------------------------------------------------------------------------
# Kubernetes
# ----------------------------------------------------------------------------
kube_ready() { # dies unless a reachable, allowed context exists; sets KCTX
  need_tool kubectl "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
  KCTX=$(timeout "$CALL_TIMEOUT" kubectl config current-context 2>/dev/null) \
    || die $E_K8S "No Kubernetes context is configured." "Start a local cluster, e.g.: minikube start --driver=docker"
  timeout "$CALL_TIMEOUT" kubectl --request-timeout=10s get --raw /readyz >/dev/null 2>&1 \
    || timeout "$CALL_TIMEOUT" kubectl --request-timeout=10s get ns >/dev/null 2>&1 \
    || die $E_K8S "Cluster for context '$KCTX' is not reachable." "Check: kubectl cluster-info   (minikube status / start Docker Desktop)"
}

kube_context_allowed() {
  case $KCTX in
    minikube|docker-desktop|rancher-desktop|colima|orbstack|kind-*|k3d-*) return 0;;
  esac
  [[ $ALLOW_CONTEXT == 1 ]]
}

kube() { timeout "$CALL_TIMEOUT" kubectl --request-timeout=10s "$@"; }

k8s_diagnostics() {
  kube get pods -n "$APP_ID" -o wide >&2 || true
  kube get events -n "$APP_ID" --sort-by=.lastTimestamp 2>/dev/null | tail -n 10 | sed 's/^/      | /' >&2 || true
  timeout 20 kubectl logs deployment/task-manager-api -n "$APP_ID" --tail=15 2>&1 | sed -E 's#(://)[^/@ ]+@#\1***@#g; s/^/      | /' >&2 || true
}

ensure_k8s_secret() { # create only if missing: Mongo reads the root password once, so it must never be rotated here
  if kube get secret task-manager-secret -n "$APP_ID" >/dev/null 2>&1; then
    ok "Secret task-manager-secret already exists (left unchanged)"; return 0
  fi
  local f pw; f=$(mktemp); TMP_FILES+=("$f")
  if have openssl; then pw=$(openssl rand -hex 16); else pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'); fi
  printf 'MONGO_USERNAME=admin\nMONGO_PASSWORD=%s\n' "$pw" >"$f"
  kube create secret generic task-manager-secret -n "$APP_ID" --from-env-file="$f" >/dev/null \
    || die $E_K8S "Could not create the Secret." "Check permissions: kubectl auth can-i create secrets -n $APP_ID"
  ok "Secret task-manager-secret created with a random password (not displayed)"
}

load_k8s_image() { # make the locally built image visible to the cluster
  case $KCTX in
    minikube)
      have minikube || { warn "minikube command not found; cannot load the image."; return 1; }
      timeout "$BUILD_TIMEOUT" minikube image load "$K8S_IMAGE_LOCAL" >>"$LAUNCH_LOG" 2>&1 9>&- || die $E_K8S "minikube image load failed." "Run: minikube image load $K8S_IMAGE_LOCAL";;
    kind-*)
      have kind || { warn "kind command not found; cannot load the image."; return 1; }
      timeout "$BUILD_TIMEOUT" kind load docker-image "$K8S_IMAGE_LOCAL" --name "${KCTX#kind-}" >>"$LAUNCH_LOG" 2>&1 9>&- || die $E_K8S "kind load failed." "Run: kind load docker-image $K8S_IMAGE_LOCAL --name ${KCTX#kind-}";;
    docker-desktop|rancher-desktop|orbstack|colima) ;; # share the local Docker image store
    *) warn "Context '$KCTX': cannot load a local image automatically. Push the image to a registry and set TM_K8S_IMAGE=<ref>."; return 1;;
  esac
  ok "Image $K8S_IMAGE_LOCAL is available to context '$KCTX'"
}

cmd_deploy_k8s() {
  title "DEPLOY: Kubernetes (namespace $APP_ID)"
  [[ -d $K8S_DIR ]] || die $E_CONFIG "k8s/ directory not found." "Run from the project root."
  kube_ready
  kube_context_allowed || die $E_K8S "Context '$KCTX' is not a recognised local cluster; refusing to deploy there." \
    "If it is intended: TM_K8S_ALLOW_CONTEXT=1 ./run.sh deploy k8s   (or --allow-context)"
  ok "Kubernetes context '$KCTX' is reachable"
  local existed=0 loaded=0
  kube get deployment task-manager-api -n "$APP_ID" >/dev/null 2>&1 && existed=1

  if [[ -n ${TM_K8S_IMAGE:-} ]]; then
    info "Using image from TM_K8S_IMAGE (no local build): $TM_K8S_IMAGE"
  else
    docker_ready
    info "Building $K8S_IMAGE_LOCAL (timeout ${BUILD_TIMEOUT}s)..."
    timeout "$BUILD_TIMEOUT" docker build -t "$K8S_IMAGE_LOCAL" "$ROOT" >"$LOG_DIR/k8s-build.log" 2>&1 9>&- \
      || { tail -n 15 "$LOG_DIR/k8s-build.log" | sed 's/^/      | /' >&2; die $E_BUILD "Image build failed." "Full log: $LOG_DIR/k8s-build.log"; }
    ok "Image built"
    if load_k8s_image; then loaded=1; fi
  fi

  kube apply -f "$K8S_DIR/namespace.yaml" >/dev/null || die $E_K8S "Could not apply the namespace."
  ensure_k8s_secret
  kube apply -f "$K8S_DIR/" >/dev/null || die $E_K8S "kubectl apply failed." "Validate: kubectl apply --dry-run=server -f k8s/"
  ok "Manifests applied (PersistentVolumeClaim and data untouched)"
  if [[ -n ${TM_K8S_IMAGE:-} ]]; then
    kube set image deployment/task-manager-api api="$TM_K8S_IMAGE" -n "$APP_ID" >/dev/null || die $E_K8S "Could not set the API image."
  elif (( loaded && existed )); then
    kube rollout restart deployment/task-manager-api -n "$APP_ID" >/dev/null && info "Restarted API pods to pick up the rebuilt image"
  fi

  local d
  for d in mongodb task-manager-api; do
    info "Waiting for rollout of $d (timeout ${ROLLOUT_TIMEOUT}s)..."
    if ! timeout $((ROLLOUT_TIMEOUT + 10)) kubectl rollout status "deployment/$d" -n "$APP_ID" --timeout="${ROLLOUT_TIMEOUT}s" >>"$LAUNCH_LOG" 2>&1; then
      err "Rollout of $d did not complete"
      k8s_diagnostics
      hint "Look at: kubectl describe pods -n $APP_ID   (ErrImageNeverPull => the image is not inside the cluster)"
      hint "API rollback if needed: kubectl rollout undo deployment/task-manager-api -n $APP_ID"
      print_summary "FAILED (exit $E_K8S)"; exit $E_K8S
    fi
    ok "Deployment $d is rolled out"
  done
  printf '\n  Open the app : kubectl port-forward svc/task-manager-api 5000:5000 -n %s   then http://localhost:5000\n' "$APP_ID"
  printf '  (minikube)   : minikube service task-manager-api -n %s\n' "$APP_ID"
}

# ----------------------------------------------------------------------------
# check (read-only preflight) and verify (read-only deployment report)
# ----------------------------------------------------------------------------
cmd_check() {
  title "CHECK: prerequisites (read-only)"
  ensure_dirs; load_config
  local f t
  for f in Dockerfile docker-compose.yml docker-compose.dev.yml package.json src/server.js k8s/namespace.yaml .github/workflows/ci-cd.yml; do
    if [[ -f $ROOT/$f ]]; then ok "File present: $f"; else err "File missing: $f"; fi
  done
  if bash -n "$ROOT/run.sh"; then ok "run.sh syntax is valid"; else err "run.sh has a syntax error"; fi
  for t in docker curl git; do if have "$t"; then ok "Command available: $t"; else err "Command missing: $t"; fi; done
  for t in node kubectl gh shellcheck; do if have "$t"; then ok "Optional command available: $t"; else warn "Optional command not installed: $t"; fi; done
  if have docker && timeout "$CALL_TIMEOUT" docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable"
    docker_ready
    if out=$(timeout "$CALL_TIMEOUT" "${COMPOSE[@]}" config --quiet 2>&1); then ok "docker-compose.yml is valid"; else err "docker-compose.yml invalid: $(head -n1 <<<"$out")"; fi
    if stack_owns_port api; then ok "Port $API_PORT: served by this project"
    elif port_listening "$API_PORT"; then warn "Port $API_PORT is busy (start would fail); use API_HOST_PORT=<other>"
    else ok "Port $API_PORT is free"; fi
  else
    err "Docker daemon is not reachable (start Docker)"
  fi
  if have kubectl; then
    if ctx=$(timeout 5 kubectl config current-context 2>/dev/null) && timeout 10 kubectl --request-timeout=8s get ns >/dev/null 2>&1; then
      ok "Kubernetes cluster reachable (context '$ctx')"
    else warn "No reachable Kubernetes cluster (only needed for: deploy k8s)"; fi
  fi
  if (( N_FAIL )); then print_summary "CHECK FAILED"; exit $E_FAIL; fi
  print_summary "CHECK PASSED"
}

fail_or_warn() { # strict -> failure, otherwise warning (optional sections are informational)
  if [[ $1 == strict ]]; then err "$2"; else warn "$2 (skipped)"; fi
}

verify_docker() { # $1 = strict (missing stack is a failure)
  local acid ast body code
  docker_ready
  acid=$(service_cid api); ast=$(container_status "$acid")
  if [[ $ast != running ]]; then
    err "Docker: API container is '$ast' - stack is not deployed/running"; hint "Run: ./run.sh start"; return 0
  fi
  ok "Docker: API container running"
  if [[ $(container_status "$(service_cid mongo)") == running ]]; then ok "Docker: MongoDB container running ($(container_health "$(service_cid mongo)"))"; else err "Docker: MongoDB container is not running"; fi
  body=$(api_health "$API_PORT")
  if [[ $body == *"\"service\":\"$APP_ID\""* && $body == *'"database":"connected"'* ]]; then ok "API /health: database connected (port $API_PORT)"
  else err "API /health unexpected: ${body:-no response}"; return 0; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$API_PORT/api/tasks" || true)
  if [[ $code == 200 ]]; then ok "GET /api/tasks -> 200 (database query works)"; else err "GET /api/tasks -> ${code:-no response}"; fi
  if (( SMOKE )); then
    local resp id
    resp=$(curl -s --max-time 5 -X POST "http://127.0.0.1:$API_PORT/api/tasks" -H 'Content-Type: application/json' -d '{"title":"run.sh smoke test"}' || true)
    id=$(sed -nE 's/.*"_id":"([0-9a-f]{24})".*/\1/p' <<<"$resp")
    if [[ -n $id ]]; then
      if curl -fsS --max-time 5 -X DELETE "http://127.0.0.1:$API_PORT/api/tasks/$id" >/dev/null 2>&1; then
        ok "Write smoke test: created and deleted its own task"
      else warn "Smoke task $id created but not deleted; remove it in the UI"; fi
    else err "Write smoke test failed: POST /api/tasks returned: ${resp:-nothing}"; fi
  fi
}

verify_k8s() { # $1 = strict
  if ! have kubectl; then
    fail_or_warn "$1" "Kubernetes: kubectl not installed"; return 0
  fi
  if ! KCTX=$(timeout 5 kubectl config current-context 2>/dev/null) || ! kube get ns >/dev/null 2>&1; then
    fail_or_warn "$1" "Kubernetes: no reachable cluster"; return 0
  fi
  if ! kube get ns "$APP_ID" >/dev/null 2>&1; then
    fail_or_warn "$1" "Kubernetes: namespace $APP_ID not deployed on '$KCTX' (run: ./run.sh deploy k8s)"; return 0
  fi
  ok "Kubernetes: namespace $APP_ID exists on '$KCTX'"
  local d ready want
  for d in mongodb task-manager-api; do
    ready=$(kube get deployment "$d" -n "$APP_ID" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    want=$(kube get deployment "$d" -n "$APP_ID" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
    if [[ -n $want && ${ready:-0} == "$want" ]]; then ok "Kubernetes: $d ready ($ready/$want)"; else err "Kubernetes: $d not ready (${ready:-0}/${want:-?})"; fi
  done
  if [[ $(kube get pvc mongodb-pvc -n "$APP_ID" -o jsonpath='{.status.phase}' 2>/dev/null || true) == Bound ]]; then
    ok "Kubernetes: PVC mongodb-pvc is Bound"
  else err "Kubernetes: PVC mongodb-pvc is not Bound"; fi
}

verify_ci() { # $1 = strict
  if ! have git || ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then warn "Git: not a git repository"; return 0; fi
  local remote; remote=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#(://)[^/@]+@#\1#' || true)
  if [[ -z $remote ]]; then warn "Git: no 'origin' remote; push to GitHub to run the workflow"; return 0; fi
  ok "Git: origin = $remote"
  if [[ -z $(git -C "$ROOT" status --porcelain 2>/dev/null) ]]; then ok "Git: working tree clean"; else warn "Git: uncommitted changes (workflow runs only on pushed commits)"; fi
  if ! have gh; then warn "GitHub CLI 'gh' not installed; cannot query workflow runs"; return 0; fi
  if ! timeout "$CALL_TIMEOUT" gh auth status >/dev/null 2>&1; then
    fail_or_warn "$1" "GitHub: gh is not authenticated (run: gh auth login)"; return 0
  fi
  local line
  if line=$(timeout "$CALL_TIMEOUT" gh run list --limit 1 --json status,conclusion,name,headBranch --template '{{range .}}{{.name}} on {{.headBranch}}: {{.status}} {{.conclusion}}{{end}}' 2>/dev/null) && [[ -n $line ]]; then
    case $line in *success*) ok "GitHub Actions: $line";; *failure*|*cancelled*) err "GitHub Actions: $line";; *) warn "GitHub Actions: $line";; esac
  else warn "GitHub Actions: no runs found or repository not reachable"; fi
}

cmd_verify() {
  title "VERIFY: deployment report (read-only)"
  ensure_dirs; load_config
  local t="${TARGET:-all}"
  case $t in
    docker) verify_docker strict;;
    k8s)    verify_k8s strict;;
    ci)     verify_ci strict;;
    all)    verify_docker strict; verify_k8s loose; verify_ci loose;;
    *) die $E_USAGE "Unknown verify target '$t'." "Use: ./run.sh verify [docker|k8s|ci|all] [--smoke]";;
  esac
  if (( N_FAIL )); then print_summary "VERIFY FAILED"; exit $E_FAIL; fi
  print_summary "VERIFY PASSED"
}

cmd_deploy() {
  local t="${TARGET:-docker}"
  case $t in
    docker) cmd_start;;
    k8s)    ensure_dirs; load_config; acquire_lock; cmd_deploy_k8s; verify_k8s strict
            if (( N_FAIL )); then print_summary "FAILED (exit $E_K8S)"; exit $E_K8S; fi; print_summary "SUCCESS";;
    all)    ensure_dirs; load_config
            local rc=0 opts=()
            [[ $EXPOSE_DB == 1 ]] && opts+=(--expose-db)
            release_lock
            bash "$ROOT/run.sh" start "${opts[@]}" || rc=$?   # child process: its own summary and exit code
            (( rc == 0 )) || { err "Docker deployment failed (exit $rc); Kubernetes step skipped"; exit "$rc"; }
            acquire_lock
            cmd_deploy_k8s; verify_k8s strict
            if (( N_FAIL )); then print_summary "FAILED (exit $E_K8S)"; exit $E_K8S; fi; print_summary "SUCCESS";;
    *) die $E_USAGE "Unknown deploy target '$t'." "Use: ./run.sh deploy [docker|k8s|all]";;
  esac
}

# ----------------------------------------------------------------------------
usage() {
  cat <<'EOF'
DevOps Task Manager launcher

Usage: ./run.sh <command> [options]

Commands
  start               Build and start API + MongoDB (Docker Compose); waits until healthy.
  stop [--remove]     Stop containers (data kept). --remove also removes containers
                      and the network. Volumes are NEVER deleted by this script.
  restart             stop + start.
  status              Containers and API health. Exit 0 running, 3 not running, 4 unhealthy.
  logs [api|mongo|launcher] [-f] [-n N]
                      Show recent logs (default last 100 lines; -f follows).
  check               Read-only prerequisite check (tools, daemon, compose file, ports).
  verify [docker|k8s|ci|all] [--smoke]
                      Read-only deployment report. --smoke creates and deletes one task.
  deploy [docker|k8s|all]
                      docker (default): same as start. k8s: build image, load it into the
                      local cluster, apply k8s/, wait for rollout. all: both.
  help                This text.

Options
  --expose-db         Also publish MongoDB on 127.0.0.1:$MONGO_HOST_PORT (default 27017)
                      for running the API with "npm start". Off by default.
  --allow-context     Allow deploy k8s on a non-local kubectl context.

Environment
  API_HOST_PORT=5000   MONGO_HOST_PORT=27017   (also read from .env)
  TM_START_TIMEOUT=120 TM_BUILD_TIMEOUT=600 TM_ROLLOUT_TIMEOUT=300
  TM_K8S_IMAGE=<registry/image:tag>   use a pushed image instead of a local build

Exit codes: 0 ok | 1 check/verify failed | 2 usage | 3 not running | 4 unhealthy
            10 tool missing | 11 config | 20 port busy | 24 docker | 25 build
            30 timeout | 34 lock | 40 kubernetes
Logs: logs/launcher.log (this script), logs/compose-up.log (last build/start)
EOF
}

parse_args() {
  CMD="${1:-help}"; shift || true
  while (( $# )); do
    case $1 in
      --expose-db) EXPOSE_DB=1;;
      --remove) REMOVE_CONTAINERS=1;;
      -f|--follow) FOLLOW=1;;
      --smoke) SMOKE=1;;
      --allow-context) ALLOW_CONTEXT=1;;
      -n|--tail) shift; [[ ${1:-} =~ ^[0-9]+$ ]] || { echo "ERROR -n needs a number" >&2; exit $E_USAGE; }; TAIL_LINES=$1;;
      -h|--help) CMD=help;;
      -*) echo "ERROR Unknown option: $1 (see ./run.sh help)" >&2; exit $E_USAGE;;
      *) POSITIONAL+=("$1");;
    esac
    shift
  done
  TARGET="${POSITIONAL[0]:-}"
}

main() {
  parse_args "$@"
  cd -- "$ROOT"
  case $CMD in
    start)   cmd_start;;
    stop)    cmd_stop;;
    restart) cmd_restart;;
    status)  cmd_status;;
    logs)    cmd_logs;;
    check)   cmd_check;;
    verify)  cmd_verify;;
    deploy)  cmd_deploy;;
    help)    usage;;
    *) echo "ERROR Unknown command: $CMD" >&2; usage >&2; exit $E_USAGE;;
  esac
}

main "$@"
