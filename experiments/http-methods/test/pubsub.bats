#!/usr/bin/env bats
# bats file_tags=http-methods

# Exercises GET, POST, PUT and DELETE through the pub/sub app, against a running sampo
# built with one of the options.  lab.sh test starts the server and sets:
#   OPTION   a-passthrough, b-method-routes or c-method-files
#   PORT     the port sampo is listening on

setup() {
  load '../../../test/test_helper/bats-support/load'
  load '../../../test/test_helper/bats-assert/load'
  BASE_URL="http://127.0.0.1:${PORT:-1042}"
}

# pick() prints the argument for the option under test: pick A B C
pick() {
  case "${OPTION:-}" in
    a-passthrough) echo "$1" ;;
    b-method-routes) echo "$2" ;;
    c-method-files) echo "$3" ;;
    *) echo "OPTION must be set" >&2; return 1 ;;
  esac
}

# http() makes a request, then prints the status code on the first line and the body after it.
# A body of @FILE sends the contents of FILE, as with curl --data-binary.
# The response headers are left in $BATS_TEST_TMPDIR/headers.
http() {
  local body=()
  if [[ $# -ge 3 ]]; then
    body=(--data-binary "$3")
  fi
  curl -s --max-time 5 -X "$1" "${body[@]+"${body[@]}"}" -D "$BATS_TEST_TMPDIR/headers" \
    -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}\n' "$BASE_URL$2"
  tr -d '\r' < "$BATS_TEST_TMPDIR/body"
}

# header() prints the value of a response header from the last http() call
header() {
  tr -d '\r' < "$BATS_TEST_TMPDIR/headers" | awk -v name="$1" -F': ' 'tolower($1) == tolower(name) {print $2}'
}

# eventually() retries a command for up to five seconds
eventually() {
  local i
  for i in $(seq 50); do
    if "$@"; then
      return 0
    fi
    sleep 0.1
  done
  "$@"
}

# subscribe() streams a topic into a file in the background, and prints curl's PID
subscribe() {
  curl -sN -i "$BASE_URL/topics/$1" > "$BATS_TEST_TMPDIR/$2" 3>&- &
  echo "$!"
}

# subscribers() is true once GET /topics shows topic $1 with $2 subscribers
# (curl -i holds the response headers back until the first message, so ask the server instead)
subscribers() {
  curl -s "$BASE_URL/topics" | tr -d '\r' | awk -F'\t' -v topic="$1" -v n="$2" '
    $1 == topic && $2 == n { found = 1 }
    END { exit !found }'
}

# stream() prints what a subscriber received after the response headers
stream() {
  tr -d '\r' < "$BATS_TEST_TMPDIR/$1" | sed '1,/^$/d'
}

# stream_has() is true once a subscriber has received a line
stream_has() {
  stream "$1" | grep -qxF "$2"
}

# ended() is true once a process has exited
ended() {
  ! kill -0 "$1" 2> /dev/null
}

@test "PUT creates a topic (201), and updates it after that (200)" {
  run http PUT /topics/created "a new topic"
  assert_line --index 0 201
  assert_line --index 1 "created topic created"
  assert_equal "$(header Location)" "/topics/created"

  run http PUT /topics/created "a better description"
  assert_line --index 0 200
  assert_line --index 1 "updated topic created"

  run http GET /topics
  assert_line --index 0 200
  assert_line "$(printf 'created\t0\ta better description')"
  http DELETE /topics/created
}

@test "subscribers get each POST as it is published, until DELETE ends their streams" {
  run http PUT /topics/stream "streaming test"
  assert_line --index 0 201
  first=$(subscribe stream first)
  second=$(subscribe stream second)
  eventually subscribers stream 2

  run http POST /topics/stream "one"
  assert_line --index 0 202
  assert_line --index 1 "published to 2 subscriber(s) of stream"
  eventually stream_has first "one"
  eventually stream_has second "one"
  # nothing is buffered: each subscriber has 'one' before 'two' is even published
  run http POST /topics/stream $'two\nthree'
  assert_line --index 0 202
  eventually stream_has first "three"
  eventually stream_has second "three"

  run http DELETE /topics/stream
  assert_line --index 0 204
  eventually ended "$first"
  eventually ended "$second"
  assert_equal "$(stream first)" $'one\ntwo\nthree'
  assert_equal "$(stream second)" $'one\ntwo\nthree'
  assert grep -q '^Content-Type: text/plain' "$BATS_TEST_TMPDIR/first"
}

@test "a deleted topic is gone for GET, POST and DELETE (404)" {
  http PUT /topics/doomed
  run http DELETE /topics/doomed
  assert_line --index 0 204
  run http GET /topics/doomed
  assert_line --index 0 404
  run http POST /topics/doomed "anyone there?"
  assert_line --index 0 404
  run http DELETE /topics/doomed
  assert_line --index 0 404
}

@test "the body is passed on byte for byte, including UTF-8" {
  http PUT /topics/utf8
  sub=$(subscribe utf8 utf8)
  eventually subscribers utf8 1
  run http POST /topics/utf8 "héllo wörld ✓"
  assert_line --index 0 202
  eventually stream_has utf8 "héllo wörld ✓"
  http DELETE /topics/utf8
  eventually ended "$sub"
}

@test "a large message arrives intact, and quickly" {
  http PUT /topics/large
  sub=$(subscribe large large)
  eventually subscribers large 1
  # bigger than a FIFO's buffer, and ending in a newline, which is dropped
  big="$(head -c 200000 /dev/zero | tr '\0' 'x')"
  echo "$big" > "$BATS_TEST_TMPDIR/big"
  run http POST /topics/large "@$BATS_TEST_TMPDIR/big"
  assert_line --index 0 202
  assert_line --index 1 "published to 1 subscriber(s) of large"
  large_arrived() {
    [[ "$(stream large)" == "$big" ]]
  }
  eventually large_arrived
  http DELETE /topics/large
  eventually ended "$sub"
}

@test "a subscriber that disconnects is dropped after the next message" {
  http PUT /topics/leaving
  sub=$(subscribe leaving leaving)
  eventually subscribers leaving 1
  kill "$sub"
  # the server notices the disconnect when it next writes to the subscriber
  http POST /topics/leaving "is anyone still there?"
  zero_subscribers() {
    http POST /topics/leaving "hello?" | grep -qx "published to 0 subscriber(s) of leaving"
  }
  eventually zero_subscribers
  http DELETE /topics/leaving
}

@test "bad requests get 400: an invalid topic name, or nothing to publish" {
  run http PUT '/topics/no%20spaces'
  assert_line --index 0 400
  http PUT /topics/empty
  run http POST /topics/empty
  assert_line --index 0 400
  http DELETE /topics/empty
}

@test "a method sampo doesn't know gets 501" {
  run http PATCH /topics/news "patch"
  assert_line --index 0 501
}

@test "a method a resource doesn't support gets 405 with an Allow header" {
  run http DELETE /topics
  assert_line --index 0 405
  assert_equal "$(header Allow)" "GET"
}

@test "external scripts get the method in \$REQUEST_METHOD and the body on STDIN" {
  run curl -s -X POST -H 'Content-Type: text/plain' --data-binary 'hello script' "$BASE_URL/inspect"
  assert_success
  assert_output --partial "method: POST"
  assert_output --partial "content type: text/plain"
  assert_output --partial "content length: 12"
  assert_output --partial "body: hello script"
}

@test "GET on a POST-only script: A runs it anyway, B and C answer 405" {
  run http GET /inspect
  assert_line --index 0 "$(pick 200 405 405)"
}

@test "existing GET routes still work" {
  run http GET /example
  assert_line --index 0 200
  assert_line --index 1 "This is an example of an external script."
}

@test "existing GET routes and other methods: A runs them, B answers 405, C answers 501 as before" {
  run http DELETE /example
  assert_line --index 0 "$(pick 200 405 501)"
  run http POST /dir//
  assert_line --index 0 "$(pick 200 405 501)"
}

@test "a request for an unknown endpoint gets one 404, whatever its method" {
  run curl -s -i -X POST --data-binary "x" "$BASE_URL/nope"
  assert_equal "$(grep -c '^HTTP/1.0 ' <<< "$output")" 1
  assert_line --partial "HTTP/1.0 404"
}

@test "/ lists the pub/sub routes" {
  run http GET /
  assert_line --index 0 200
  assert_line "$(pick "/topics:topics_resource" "GET /topics:topic_list" "GET /topics:routes/topics/GET.sh")"
  assert_line "$(pick "/topics/:topic_resource" "DELETE /topics/:topic_delete" "DELETE /topics/@:routes/topics/@/DELETE.sh")"
}
