#!/usr/bin/env bash
#
# lab.sh: build, serve, demo and test the three ways of adding POST, PUT and DELETE to sampo
#
# Each option is docker/sampo as it was before option B went into it (commit BASELINE), plus patches:
#   common/0-linux-logging.patch   log to a file on Linux hosts (a fix sampo needed anyway; see README)
#   common/1-request-body.patch    read the request body and hand it to handlers (all options)
#   OPTION/sampo.sh.patch          how OPTION routes methods
#   OPTION/sampo.conf.patch        how OPTION wires up the pub/sub app, if it uses sampo.conf
#   OPTION/routes/                 option c's handler files
#
set -eE
set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
BATS="$REPO/test/test_helper/bats-core/bin/bats"
OPTIONS=(a-passthrough b-method-routes c-method-files)
# the last commit before sampo had option B; the patches apply to its docker/sampo
BASELINE=294d3b75c54e1cdb4a722a882fc0caa6c0a47453

#/ Usage: lab.sh COMMAND [ARGS]
#/
#/   OPTION is a, b or c (or a-passthrough, b-method-routes, c-method-files);
#/   'original' is sampo as it was before any of them, and 'current' is docker/sampo as it
#/   is now (which has option B), with the pub/sub app wired up the way option B does it
#/
#/   build OPTION DIR       put a runnable sampo folder for OPTION in DIR
#/   serve OPTION [PORT]    serve OPTION on PORT (default 1042) until Ctrl-C
#/   demo OPTION [PORT]     serve OPTION and stream a topic to this terminal while publishing to it
#/   test [OPTION...]       run test/pubsub.bats against each OPTION (default: all three)
#/   regress [OPTION...]    run sampo's own test/sampo_integration.bats against each OPTION built
#/                          with the stock sampo.conf (default: original and all three; the
#/                          tests come from the same commit as the OPTION's sampo)
#/   matrix [PORT]          show the status codes each OPTION answers a set of requests with
#/
#/   Servers run on this machine with socat, unless SAMPO_DOCKER_IMAGE names an image to run
#/   instead (SAMPO_DOCKER_CMD overrides its command), e.g.
#/     SAMPO_DOCKER_IMAGE=ghcr.io/jacobsalmela/sampo/sampo:1.0.0 ./lab.sh demo b
usage() {
  grep '^#/' "${BASH_SOURCE[0]}" | cut -c4-
}

die() {
  echo "lab.sh: $*" >&2
  exit 1
}

# option_dir() turns a, b, c, original or current into the option's directory name
option_dir() {
  case "$1" in
    a|a-passthrough) echo "a-passthrough" ;;
    b|b-method-routes) echo "b-method-routes" ;;
    c|c-method-files) echo "c-method-files" ;;
    original) echo "original" ;;
    current) echo "current" ;;
    *) die "unknown option '$1': use a, b, c, original or current" ;;
  esac
}

# from_baseline() writes the BASELINE commit's version of file $1 (a path in the repo) to STDOUT
from_baseline() {
  git -C "$REPO" show "$BASELINE:$1" 2> /dev/null \
    || die "can't read $1 from commit $BASELINE: lab.sh needs a git clone of sampo with that commit"
}

# lab_build() puts a runnable sampo folder for option $1 in $2
# with a third argument, --no-app, it leaves out the pub/sub app and keeps the stock sampo.conf
lab_build() {
  local option src out="$2"
  option="$(option_dir "$1")"
  src="$HERE/$option"
  mkdir -p "$out"
  if [[ "$option" == "current" ]]; then
    cp -R "$REPO/docker/sampo/." "$out/"
    src="$HERE/b-method-routes"
  else
    git -C "$REPO" archive "$BASELINE" docker/sampo | tar -x -f - -C "$out" --strip-components=2 \
      || die "can't read docker/sampo from commit $BASELINE: lab.sh needs a git clone of sampo with that commit"
    patch -s -p1 -d "$out" < "$HERE/common/0-linux-logging.patch"
    if [[ "$option" == "original" ]]; then
      return 0
    fi
    patch -s -p1 -d "$out" < "$HERE/common/1-request-body.patch"
    patch -s -p1 -d "$out" < "$src/sampo.sh.patch"
  fi
  if [[ "${3:-}" == "--no-app" ]]; then
    return 0
  fi
  if [[ -f "$src/sampo.conf.patch" ]]; then
    patch -s -p1 -d "$out" < "$src/sampo.conf.patch"
  fi
  if [[ -d "$src/routes" ]]; then
    cp -R "$src/routes" "$out/routes"
  fi
  cp "$HERE/common/pubsub.sh" "$out/pubsub.sh"
  cp "$HERE/common/inspect.sh" "$out/scripts/inspect.sh"
  chmod 755 "$out/scripts/inspect.sh"
}

# lab_start() builds option $1 in folder $3 and serves it on port $2 in the background
# (a fourth argument is passed on to lab_build)
lab_start() {
  local port="$2" dir="$3" i
  lab_build "$1" "$dir" "${4:-}"
  if [[ -n "${SAMPO_DOCKER_IMAGE:-}" ]]; then
    # shellcheck disable=SC2086 # SAMPO_DOCKER_CMD is a command line
    docker run -d --rm --name "sampo-lab-$port" -p "127.0.0.1:$port:1042" -v "$dir":/sampo \
      "$SAMPO_DOCKER_IMAGE" ${SAMPO_DOCKER_CMD:-} > /dev/null
  else
    command -v socat > /dev/null || die "socat is needed to serve sampo locally"
    # stop the pub/sub app's topics from leaking between runs
    PUBSUB_DIR="$dir/pubsub" socat TCP-LISTEN:"$port",reuseaddr,fork,pf=ip4,bind=127.0.0.1 \
      EXEC:"$dir/sampo.sh" 2>> "$dir/socat.log" 3>&- &
    echo "$!" > "$dir/socat.pid"
  fi
  for i in $(seq 100); do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/"; then
      return 0
    fi
    sleep 0.1
  done
  die "sampo did not start on port $port"
}

# lab_stop() stops the server that lab_start() started on port $1 from folder $2
lab_stop() {
  local port="$1" dir="$2"
  if [[ -n "${SAMPO_DOCKER_IMAGE:-}" ]]; then
    docker stop "sampo-lab-$port" > /dev/null 2>&1 || true
  elif [[ -f "$dir/socat.pid" ]]; then
    kill "$(cat "$dir/socat.pid")" 2> /dev/null || true
    # also stop requests still being served, like subscribers waiting for messages
    pkill -f "$dir/sampo.sh" 2> /dev/null || true
    rm -f "$dir/socat.pid"
  fi
}

# stop_on_exit() makes sure the server on port $1 is stopped, and folder $2 removed, when lab.sh exits
stop_on_exit() {
  # shellcheck disable=SC2064 # expand now: the caller's variables are gone by the time lab.sh exits
  trap "lab_stop $(printf %q "$1") $(printf %q "$2"); rm -rf $(printf %q "$2")" EXIT
}

lab_serve() {
  local option port="${2:-1042}" dir
  option="$(option_dir "$1")"
  dir="$(mktemp -d "${TMPDIR:-/tmp}/sampo-$option.XXXXXX")"
  stop_on_exit "$port" "$dir"
  lab_start "$option" "$port" "$dir"
  cat << EOF
sampo ($option) is listening on http://localhost:$port, serving $dir
Try it from another terminal:
  curl -X PUT -d 'Daily headlines' localhost:$port/topics/news   # create a topic
  curl -N localhost:$port/topics/news                              # subscribe: messages stream in
  curl -X POST -d 'hello' localhost:$port/topics/news              # publish (from a third terminal)
  curl localhost:$port/topics                                      # list topics and subscribers
  curl -X DELETE localhost:$port/topics/news                       # delete it, ending the stream
Press Ctrl-C to stop.
EOF
  while sleep 60; do :; done
}

# client() makes a request and prints the status code and response body on one line
client() {
  local method="$1" path="$2" body=()
  if [[ $# -ge 3 ]]; then
    body=(--data-binary "$3")
  fi
  local response
  response="$(curl -s -X "$method" "${body[@]+"${body[@]}"}" -w '(%{http_code})' "http://127.0.0.1:$PORT$path" | tr -d '\r' | tr '\n' ' ')"
  # one printf, so the subscriber's lines cannot land in the middle of this one
  printf '%s  %-7s %-13s -> %s\n' "$(date +%H:%M:%S)" "$method" "$path" "$response"
}

lab_demo() {
  local option dir subscriber
  option="$(option_dir "$1")"
  PORT="${2:-1042}"
  dir="$(mktemp -d "${TMPDIR:-/tmp}/sampo-$option.XXXXXX")"
  stop_on_exit "$PORT" "$dir"
  lab_start "$option" "$PORT" "$dir"
  echo "== sampo ($option) on port $PORT"
  client PUT /topics/news "Daily headlines"

  echo "== subscribing to /topics/news; the stream's lines appear as '| ...'"
  curl -sN "http://127.0.0.1:$PORT/topics/news" | while IFS= read -r line; do
    printf '%s  | %s\n' "$(date +%H:%M:%S)" "${line%$'\r'}"
  done &
  subscriber=$!
  sleep 1

  client POST /topics/news "hello from sampo"
  sleep 1
  client POST /topics/news "each POST is streamed to the subscriber right away"
  sleep 1
  client POST /topics/news $'a message can have\nmore than one line'
  sleep 1
  client GET /topics
  client DELETE /topics/news
  wait "$subscriber" || true
  echo "== the stream ended when the topic was deleted"
}

lab_test() {
  local option dir status=0 port=18042
  [[ -x "$BATS" ]] || die "bats is missing: git submodule update --init"
  if [[ $# -eq 0 ]]; then
    set -- "${OPTIONS[@]}"
  fi
  for option in "$@"; do
    option="$(option_dir "$option")"
    dir="$(mktemp -d "${TMPDIR:-/tmp}/sampo-$option.XXXXXX")"
    stop_on_exit "$port" "$dir"
    echo "== $option"
    lab_start "$option" "$port" "$dir"
    OPTION="$option" PORT="$port" "$BATS" "$HERE/test/pubsub.bats" || status=1
    lab_stop "$port" "$dir"
    rm -rf "$dir"
  done
  return "$status"
}

# lab_regress() runs sampo's own integration tests against each option, with the stock sampo.conf:
# the options built from commit BASELINE get that commit's tests, and 'current' gets today's
lab_regress() {
  local option dir tests status=0 port=18044
  [[ -x "$BATS" ]] || die "bats is missing: git submodule update --init"
  if [[ $# -eq 0 ]]; then
    set -- original "${OPTIONS[@]}"
  fi
  for option in "$@"; do
    option="$(option_dir "$option")"
    dir="$(mktemp -d "${TMPDIR:-/tmp}/sampo-$option.XXXXXX")"
    stop_on_exit "$port" "$dir"
    tests="$REPO/test/sampo_integration.bats"
    if [[ "$option" != "current" ]]; then
      # put the old tests next to the helpers they load
      mkdir "$dir/lab-tests"
      from_baseline test/sampo_integration.bats > "$dir/lab-tests/sampo_integration.bats"
      ln -s "$REPO/test/test_helper" "$dir/lab-tests/test_helper"
      tests="$dir/lab-tests/sampo_integration.bats"
    fi
    echo "== $option, with the stock sampo.conf"
    lab_start "$option" "$port" "$dir" --no-app
    PORT="$port" "$BATS" "$tests" || status=1
    lab_stop "$port" "$dir"
    rm -rf "$dir"
  done
  return "$status"
}

# status_line() prints the status code(s) sampo answers a request with ('none' for an empty reply)
status_line() {
  local codes
  codes="$(curl -s -i --max-time 2 -X "$1" ${3:+--data-binary "$3"} "http://127.0.0.1:$PORT$2" \
    | tr -d '\r' | awk '/^HTTP\/1\.[01] [0-9]+/ {print $2}' | paste -sd+ - || true)"
  echo "${codes:-none}"
}

lab_matrix() {
  local option dir i n
  local -a codes=() requests=(
    "PUT /topics/news hi"
    "POST /topics/news hello"
    "GET /topics"
    "DELETE /topics/news"
    "PATCH /topics/news"
    "DELETE /topics"
    "POST /inspect hi"
    "GET /inspect"
    "GET /example"
    "DELETE /example"
    "POST /dir//"
    "POST /nope"
    "GET /example/extra"
  )
  PORT="${1:-18043}"
  n="${#requests[@]}"
  # codes[] holds each option's answers in turn: original, then a, b and c
  for option in original "${OPTIONS[@]}"; do
    dir="$(mktemp -d "${TMPDIR:-/tmp}/sampo-$option.XXXXXX")"
    stop_on_exit "$PORT" "$dir"
    lab_start "$option" "$PORT" "$dir"
    for i in "${!requests[@]}"; do
      # shellcheck disable=SC2086 # split "METHOD PATH [BODY]"
      codes+=("$(status_line ${requests[$i]})")
    done
    lab_stop "$PORT" "$dir"
    rm -rf "$dir"
  done
  printf '| %-26s | %-8s | %-13s | %-15s | %-14s |\n' request original a-passthrough b-method-routes c-method-files
  printf '|%s|%s|%s|%s|%s|\n' "$(printf -- '-%.0s' {1..28})" "$(printf -- '-%.0s' {1..10})" \
    "$(printf -- '-%.0s' {1..15})" "$(printf -- '-%.0s' {1..17})" "$(printf -- '-%.0s' {1..16})"
  for i in "${!requests[@]}"; do
    # shellcheck disable=SC2086
    set -- ${requests[$i]}
    printf '| %-26s | %-8s | %-13s | %-15s | %-14s |\n' "\`$1 $2\`" "${codes[$i]}" \
      "${codes[$((n + i))]}" "${codes[$((2 * n + i))]}" "${codes[$((3 * n + i))]}"
  done
}

# run the command line, unless this file is being sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command="${1:-}"
  shift || true
  case "$command" in
    build)  [[ $# -eq 2 ]] || { usage; exit 1; }; lab_build "$@" ;;
    serve)  [[ $# -ge 1 ]] || { usage; exit 1; }; lab_serve "$@" ;;
    demo)   [[ $# -ge 1 ]] || { usage; exit 1; }; lab_demo "$@" ;;
    test)   lab_test "$@" ;;
    regress) lab_regress "$@" ;;
    matrix) lab_matrix "$@" ;;
    *)      usage; exit 1 ;;
  esac
fi
