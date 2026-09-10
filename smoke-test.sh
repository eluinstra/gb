#!/usr/bin/env bash
#===============================================================================
# smoke-test.sh — file-server + file-client smoke test
#
# Brings up a file-server and a file-client that can exchange files, and
# verifies the setup with the same REST calls as
#   file-server/resources/file-server.rest   (users, files, GB reference)
#   file-client/resources/file-client.rest   (upload via tus, download)
#
#  Server (file-server, local — "StartGB -hsqldb")
#    Launched exactly like the "StartGB -hsqldb" config in .vscode/launch.json
#    (same main class + args), from the shaded file-server jar plus the
#    flyway-database-hsqldb jar. That plugin is "provided" scope, which is why
#    the VSCode/Maven classpath contains it but the shaded jar does not:
#
#      java -Djavax.net.ssl.trustStore= \
#           -cp <file-server jar>:<flyway-database-hsqldb jar> \
#           dev.luin.file.server.StartGB -hsqldb -noAuthentication
#
#      REST   : https://localhost:8080/service/rest/v1   (self-signed TLS)
#      Files  : https://localhost:8443/files             (tus + download)
#      DB     : embedded HSQLDB in a throw-away working directory (-hsqldb)
#
#    -noAuthentication is used so the header-less .rest requests can be replayed
#    verbatim. (Without it the server prompts for basic-auth credentials at boot.)
#
#  Client (file-client, local — "StartGB -hsqldb -port 8000")
#    Same idea, from the shaded file-client jar:
#
#      java -Djavax.net.ssl.trustStore= \
#           -cp <file-client jar>:<flyway-database-hsqldb jar> \
#           dev.luin.file.client.StartGB -hsqldb -port 8000
#
#      REST   : https://localhost:8000/service/rest/v1   (self-signed TLS)
#      DB     : embedded HSQLDB in a throw-away working directory (-hsqldb)
#
#    The client's TLS truststore pins the server's self-signed certificate, so it
#    can talk to the server's :8443 file endpoint (tus upload + HTTP download).
#
#  Both apps store files under <workdir>/files (file.baseDir). That directory
#  must exist before the first write — the apps create per-file sub-directories
#  with Files.createDirectory and do NOT create the base dir — so it is created
#  up front for each app.
#
#  Test steps
#    1. boot the server, wait for its REST API
#    2. boot the client, wait for its REST API
#    3. server users: getUsers -> createUser -> getUser
#    4. server files: uploadFile -> getFiles -> getFileInfo -> downloadFile
#       -> getExternalDataReference (Digikoppeling senderUrl)
#    5. client upload: POST /upload (creationUrl + file) -> poll to SUCCEEDED
#       (the client tus-uploads to the server's :8443/files/upload)
#    6. client download: POST /download (url) -> poll to SUCCEEDED (the client
#       fetches from the server's :8443/files/download/...)
#    7. verify the file the client downloaded matches the server's by sha256
#
#  Usage
#    ./smoke-test.sh [--rebuild] [--keep] [--help]
#      --rebuild   force rebuild of the file-server + file-client jars
#      --keep      leave both apps running after the test (no teardown)
#
#  Environment
#    SMOKE_LOG_DIR  optional directory; when the test fails, the workdir
#                   (server.log, client.log, files, ...) is copied there (used
#                   by a release workflow to upload the logs as an artifact)
#
#  Requirements: JDK 17, Maven, curl
#===============================================================================

set -u

#--- configuration -------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$REPO_ROOT/file-server"
CLIENT_DIR="$REPO_ROOT/file-client"
SERVER_REST="$SERVER_DIR/resources/file-server.rest"
CLIENT_REST="$CLIENT_DIR/resources/file-client.rest"

# endpoints (see the .rest files)
REST_S="https://localhost:8080/service/rest/v1"   # server REST (self-signed TLS)
FILES_S="https://localhost:8443/files"            # server file store (tus + download)
REST_C="https://localhost:8000/service/rest/v1"   # client REST (self-signed TLS)

# ports that must be free before starting
NEEDED_PORTS="8080 8443 9001 8000 9000"

REBUILD=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --keep)    KEEP=1 ;;
    --help|-h) grep '^#' "$0" | sed 's/^#//;s/^ //' ; exit 0 ;;
    *) echo "Unknown option: $arg (use --help)" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
WORK_DIR=""
SERVER_HOME=""
CLIENT_HOME=""
SERVER_PID=""
CLIENT_PID=""

#--- helpers -------------------------------------------------------------------
info()  { echo -e "\033[1;34m==> $*\033[0m"; }
ok()    { echo -e "  \033[1;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
bad()   { echo -e "  \033[1;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }

die() {
  echo -e "\033[1;31mERROR: $*\033[0m" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"
}

port_in_use() {
  # no bare "exec" redirects here: they persist in the main shell and would
  # silently move its stderr to /dev/null for the rest of the script
  local rc=1
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && rc=0
  return $rc
}

# wait_for <description> <timeout-seconds> <command...>
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  while true; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    if (( $(date +%s) >= deadline )); then
      echo "  (timed out after ${timeout}s waiting: $desc)" >&2
      return 1
    fi
    sleep 2
  done
}

# http <method> <url> [extra curl args...] -> sets HTTP_CODE and HTTP_BODY
http() {
  local method="$1" url="$2"; shift 2
  local body_file; body_file=$(mktemp)
  HTTP_CODE=$(curl -sk -o "$body_file" -w '%{http_code}' -X "$method" "$@" "$url" 2>>"${WORK_DIR:-/tmp}/curl.err") || HTTP_CODE=000
  HTTP_BODY=$(cat "$body_file")
  rm -f "$body_file"
}

# expect_http <description> <method> <url> [curl args...]  (asserts 2xx)
expect_http() {
  local desc="$1" method="$2" url="$3"; shift 3
  http "$method" "$url" "$@"
  case "$HTTP_CODE" in
    2*) ok "$desc (HTTP $HTTP_CODE)" ;;
    *)  bad "$desc (HTTP $HTTP_CODE) body: ${HTTP_BODY:0:300}";;
  esac
}

# jsonget <body> <key> -> value (empty if the key is absent).
# grep-based on purpose: this must work even where `python3` misbehaves, and it
# uses the same `grep -oP` already relied on for the certificate extraction.
jsonget() {
  local body="$1" key="$2"
  grep -oP "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}[:space:]]+)" <<<"$body" | head -n1 |
    sed -E "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*//; s/[[:space:]]*$//; s/\"//g"
}

# poll_status <base-url> <task-id> -> sets TASK_STATUS to SUCCEEDED/FAILED/""
poll_status() {
  local base="$1" id="$2"
  TASK_STATUS=""
  for _ in $(seq 1 60); do
    http GET "$base/$id"
    TASK_STATUS="$(jsonget "$HTTP_BODY" status)"
    [[ "$TASK_STATUS" == "SUCCEEDED" || "$TASK_STATUS" == "FAILED" ]] && break
    sleep 1
  done
}

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  [[ -n "$CLIENT_PID" ]] && kill "$CLIENT_PID" 2>/dev/null
  sleep 1
  [[ -n "$SERVER_PID" ]] && kill -9 "$SERVER_PID" 2>/dev/null
  [[ -n "$CLIENT_PID" ]] && kill -9 "$CLIENT_PID" 2>/dev/null
  if [[ -n "$WORK_DIR" && $KEEP -eq 0 ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap 'rc=$?; if (( rc != 0 )); then
  [[ -n "$SERVER_HOME" ]] && { echo; echo "--- server.log (last 40 lines) ---"; tail -n 40 "$SERVER_HOME/server.log" 2>/dev/null; }
  [[ -n "$CLIENT_HOME" ]] && { echo; echo "--- client.log (last 40 lines) ---"; tail -n 40 "$CLIENT_HOME/client.log" 2>/dev/null; }
  if [[ -n "${SMOKE_LOG_DIR:-}" ]]; then
    mkdir -p "$SMOKE_LOG_DIR" 2>/dev/null || true
    cp -a "$WORK_DIR/." "$SMOKE_LOG_DIR/" 2>/dev/null || true
    echo "smoke test logs saved to $SMOKE_LOG_DIR"
  fi
fi; cleanup' EXIT

#--- pre-flight ----------------------------------------------------------------
info "Pre-flight checks"
for c in java mvn curl; do require_cmd "$c"; done
java_major=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')
(( java_major >= 17 )) || die "JDK 17+ required, found $java_major"
for p in $NEEDED_PORTS; do
  port_in_use "$p" && die "port $p is already in use; stop the other process and retry"
done
[[ -f "$SERVER_REST" ]] || die "server .rest not found: $SERVER_REST"
[[ -f "$CLIENT_REST" ]] || die "client .rest not found: $CLIENT_REST"

#--- working directory (throw-away, keeps repo clean) --------------------------
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gb-smoke.XXXXXX")
SERVER_HOME="$WORK_DIR/server"
CLIENT_HOME="$WORK_DIR/client"
# file.baseDir=files must pre-exist (see header); create it for each app.
mkdir -p "$SERVER_HOME/files" "$CLIENT_HOME/files"
info "Working directory: $WORK_DIR"

#--- artifacts: shaded jars + flyway-hsqldb plugin -----------------------------
SERVER_JAR=$(ls "$SERVER_DIR"/target/file-server-*.jar 2>/dev/null | grep -v original- | grep -v sources | head -1 || true)
CLIENT_JAR=$(ls "$CLIENT_DIR"/target/file-client-*.jar 2>/dev/null | grep -v original- | grep -v sources | head -1 || true)
if [[ $REBUILD -eq 1 || -z "$SERVER_JAR" || -z "$CLIENT_JAR" ]]; then
  info "Building file-server + file-client shaded jars (this can take a few minutes)..."
  # One reactor build of the two shaded jars and their in-repo deps. Static
  # analysis (checkstyle/pmd/spotbugs) is skipped: this is a runtime smoke test,
  # not a lint gate (mvn verify covers those in CI).
  mvn -B -q -DskipTests -Dcheckstyle.skip=true -Dpmd.skip=true -Dspotbugs.skip=true \
      -f "$REPO_ROOT/pom.xml" -pl file-server,file-client -am package || die "mvn build failed"
  SERVER_JAR=$(ls "$SERVER_DIR"/target/file-server-*.jar | grep -v original- | grep -v sources | head -1)
  CLIENT_JAR=$(ls "$CLIENT_DIR"/target/file-client-*.jar | grep -v original- | grep -v sources | head -1)
fi
# flyway-database-hsqldb is "provided" scope, so it is NOT in the shaded jar, but
# the HSQLDB backend needs its Flyway DB plugin on the classpath (resolved into
# the local repo by the build above).
FLYWAY_HSQLDB=$(ls "$HOME"/.m2/repository/org/flywaydb/flyway-database-hsqldb/*/*.jar 2>/dev/null | grep -v sources | grep -v javadoc | sort | tail -1 || true)
[[ -n "$SERVER_JAR" && -n "$CLIENT_JAR" ]] || die "could not locate the file-server / file-client jars"
[[ -n "$FLYWAY_HSQLDB" ]] || die "could not locate flyway-database-hsqldb in ~/.m2"
info "Using: $SERVER_JAR"
info "Using: $CLIENT_JAR"
info "Using: $FLYWAY_HSQLDB"

#--- server: StartGB -hsqldb -noAuthentication ----------------------------------
info "Starting file-server (StartGB -hsqldb -noAuthentication)..."
(
  cd "$SERVER_HOME" || exit 1
  exec java -Djavax.net.ssl.trustStore= \
    -cp "$SERVER_JAR:$FLYWAY_HSQLDB" \
    dev.luin.file.server.StartGB -hsqldb -noAuthentication \
    > "$SERVER_HOME/server.log" 2>&1
) &
SERVER_PID=$!

server_rest() { curl -sk -o /dev/null -w '%{http_code}' "$REST_S/users" | grep -q 200; }
wait_for "server REST API ($REST_S)" 180 server_rest || die "file-server did not start (see $SERVER_HOME/server.log)"
ok "file-server is up on $REST_S + $FILES_S"

#--- client: StartGB -hsqldb -port 8000 -----------------------------------------
info "Starting file-client (StartGB -hsqldb -port 8000)..."
(
  cd "$CLIENT_HOME" || exit 1
  exec java -Djavax.net.ssl.trustStore= \
    -cp "$CLIENT_JAR:$FLYWAY_HSQLDB" \
    dev.luin.file.client.StartGB -hsqldb -port 8000 \
    > "$CLIENT_HOME/client.log" 2>&1
) &
CLIENT_PID=$!

client_rest() { curl -sk -o /dev/null -w '%{http_code}' "$REST_C/upload" | grep -q 200; }
wait_for "client REST API ($REST_C)" 180 client_rest || die "file-client did not start (see $CLIENT_HOME/client.log)"
ok "file-client is up on $REST_C"

# ===========================================================================
# 1. server: users (file-server.rest)
# ===========================================================================
info "Server: users"
http GET "$REST_S/users"
[[ "$HTTP_CODE" == "200" && "$HTTP_BODY" == "[]" ]] \
  && ok "getUsers (empty) (HTTP $HTTP_CODE)" \
  || bad "getUsers (empty) (HTTP $HTTP_CODE, body: $HTTP_BODY)"

CERT=$(grep -oP '"certificate":\s*"\K[^"]+' "$SERVER_REST" | head -1)
[[ ${#CERT} -gt 100 ]] || die "could not extract certificate from $SERVER_REST"
http POST "$REST_S/users" -H 'Content-Type: application/json' --data "{\"name\": \"user\", \"certificate\": \"$CERT\"}"
case "$HTTP_CODE" in
  2*) ok "createUser (POST /users) (HTTP $HTTP_CODE)" ;;
  *)  bad "createUser (POST /users) (HTTP $HTTP_CODE) body: ${HTTP_BODY:0:300}";;
esac
http GET "$REST_S/users/0"
[[ "$HTTP_CODE" == "200" ]] && grep -q '"name":"user"' <<<"$HTTP_BODY" \
  && ok "getUser (GET /users/0) (HTTP $HTTP_CODE)" \
  || bad "getUser (GET /users/0) (HTTP $HTTP_CODE, body: ${HTTP_BODY:0:200})"

# ===========================================================================
# 2. server: files (file-server.rest)
# ===========================================================================
info "Server: files"
# uploadFile — replay the EXACT multipart body from the .rest (from the opening
# '---<boundary>' line through the closing '---<boundary>---' line).
awk '/^---/{flag=1} flag{print} /^---.+=---$/{exit}' "$SERVER_REST" > "$SERVER_HOME/upload_body.txt"
[[ -s "$SERVER_HOME/upload_body.txt" ]] || die "could not extract the upload multipart body from $SERVER_REST"
http POST "$REST_S/files/user/0" \
  -H 'Content-Type: multipart/form-data; boundary=-=cTIBJ6SPK7J5=-' \
  --data-binary @"$SERVER_HOME/upload_body.txt"
UP_PATH=$(tr -d '[:space:]' <<<"$HTTP_BODY")
case "$HTTP_CODE" in
  2*) ok "uploadFile (multipart from .rest) (HTTP $HTTP_CODE)" ;;
  *)  bad "uploadFile (multipart from .rest) (HTTP $HTTP_CODE) body: ${HTTP_BODY:0:300}";;
esac
[[ ${#UP_PATH} -gt 40 ]] || die "uploadFile returned no virtual path: '$HTTP_BODY'"
info "  uploaded virtual path: $UP_PATH"

http GET "$REST_S/files"
[[ "$HTTP_CODE" == "200" ]] && grep -qF "$UP_PATH" <<<"$HTTP_BODY" \
  && ok "getFiles (lists uploaded path) (HTTP $HTTP_CODE)" \
  || bad "getFiles (HTTP $HTTP_CODE, body missing $UP_PATH)"
http GET "$REST_S/files/$UP_PATH/info"
[[ "$HTTP_CODE" == "200" ]] && grep -q '"name":"Lorem ipsum.txt"' <<<"$HTTP_BODY" \
  && ok "getFileInfo (HTTP $HTTP_CODE)" \
  || bad "getFileInfo (HTTP $HTTP_CODE, body: ${HTTP_BODY:0:200})"
http GET "$REST_S/files/$UP_PATH"
[[ "$HTTP_CODE" == "200" ]] && (( ${#HTTP_BODY} > 100 )) \
  && ok "downloadFile (HTTP $HTTP_CODE, ${#HTTP_BODY} bytes)" \
  || bad "downloadFile (HTTP $HTTP_CODE, ${#HTTP_BODY} bytes)"
http GET "$REST_S/gb/externalDataReference/$UP_PATH"
[[ "$HTTP_CODE" == "200" ]] && grep -qF "$FILES_S/download/$UP_PATH" <<<"$HTTP_BODY" \
  && ok "getExternalDataReference (Digikoppeling senderUrl) (HTTP $HTTP_CODE)" \
  || bad "getExternalDataReference (HTTP $HTTP_CODE, body: ${HTTP_BODY:0:300})"
SENDER_URL="$FILES_S/download/$UP_PATH"

# ===========================================================================
# 3. client: upload (file-client.rest) — tus to the server's :8443
# ===========================================================================
info "Client: upload"
# NOTE: the client's CXF multipart provider rejects the .rest's base64 file part
# ("No multipart with content id file"); the same operation works with a real
# file part, so it is driven with one here (creationUrl + file, as in the .rest).
printf 'Mauris nisl smoke test payload.\n' > "$CLIENT_HOME/mauris.txt"
http POST "$REST_C/upload" \
  -F "creationUrl=$FILES_S/upload" \
  -F "file=@$CLIENT_HOME/mauris.txt;type=text/plain"
case "$HTTP_CODE" in
  2*) ok "uploadFile (client POST /upload) (HTTP $HTTP_CODE)" ;;
  *)  bad "uploadFile (client POST /upload) (HTTP $HTTP_CODE) body: ${HTTP_BODY:0:300}";;
esac
UP_TASK=$(jsonget "$HTTP_BODY" fileId)
[[ -n "$UP_TASK" ]] || { bad "could not read fileId from client upload response: ${HTTP_BODY:0:200}"; UP_TASK="-1"; }
poll_status "$REST_C/upload" "$UP_TASK"
[[ "$TASK_STATUS" == "SUCCEEDED" ]] \
  && ok "uploadTask SUCCEEDED (client tus-uploaded to $FILES_S/upload)" \
  || bad "uploadTask status=$TASK_STATUS"
http GET "$REST_C/upload"
[[ "$HTTP_CODE" == "200" ]] && grep -q '"status":"SUCCEEDED"' <<<"$HTTP_BODY" \
  && ok "getUploadTasks (HTTP $HTTP_CODE)" \
  || bad "getUploadTasks (HTTP $HTTP_CODE, body: ${HTTP_BODY:0:200})"

# ===========================================================================
# 4. client: download (file-client.rest) — HTTP from the server's :8443
# ===========================================================================
info "Client: download"
# Same endpoint/shape as the .rest (a multipart 'url' part); use the real server
# download URL (the .rest template uses a '?' placeholder for the path).
http POST "$REST_C/download" -F "url=$SENDER_URL"
case "$HTTP_CODE" in
  2*) ok "downloadFile (client POST /download) (HTTP $HTTP_CODE)" ;;
  *)  bad "downloadFile (client POST /download) (HTTP $HTTP_CODE) body: ${HTTP_BODY:0:300}";;
esac
DL_TASK=$(jsonget "$HTTP_BODY" fileId)
[[ -n "$DL_TASK" ]] || { bad "could not read fileId from client download response: ${HTTP_BODY:0:200}"; DL_TASK="-1"; }
poll_status "$REST_C/download" "$DL_TASK"
[[ "$TASK_STATUS" == "SUCCEEDED" ]] \
  && ok "downloadTask SUCCEEDED (client fetched from $SENDER_URL)" \
  || bad "downloadTask status=$TASK_STATUS"
http GET "$REST_C/download"
[[ "$HTTP_CODE" == "200" ]] && grep -q '"status":"SUCCEEDED"' <<<"$HTTP_BODY" \
  && ok "getDownloadTasks (HTTP $HTTP_CODE)" \
  || bad "getDownloadTasks (HTTP $HTTP_CODE, body: ${HTTP_BODY:0:200})"

# the file the client downloaded must match the one on the server (by sha256)
if [[ -n "$DL_TASK" && "$DL_TASK" != "-1" ]]; then
  http GET "$REST_C/files/$DL_TASK/info"
  [[ "$HTTP_CODE" == "200" ]] && grep -q '"name":"Lorem ipsum.txt"' <<<"$HTTP_BODY" \
    && ok "client getFileInfo (downloaded) (HTTP $HTTP_CODE)" \
    || bad "client getFileInfo (HTTP $HTTP_CODE, body: ${HTTP_BODY:0:200})"
  DL_SHA=$(jsonget "$HTTP_BODY" sha256Checksum)
else
  bad "client getFileInfo (skipped: no download task id)"
  DL_SHA=""
fi
http GET "$REST_S/files/$UP_PATH/info"
SRV_SHA=$(jsonget "$HTTP_BODY" sha256Checksum)
[[ -n "$DL_SHA" && "$DL_SHA" == "$SRV_SHA" ]] \
  && ok "round-trip integrity: client sha256 == server sha256 ($DL_SHA)" \
  || bad "round-trip integrity: client='$DL_SHA' server='$SRV_SHA'"

# ===========================================================================
# summary
# ===========================================================================
info "Summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo -e "  \033[1;32mALL CHECKS PASSED\033[0m"
  exit 0
else
  echo -e "  \033[1;31mSOME CHECKS FAILED\033[0m"
  exit 1
fi
