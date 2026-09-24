#!/usr/bin/env bats
# bats file_tags=unit

# These unit tests call the functions in sampo.sh directly, without a server.

setup() {
  # load the supplemental libraries
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SAMPO_SH="$BATS_TEST_DIRNAME/../docker/sampo/sampo.sh"
}

# sampo CODE runs CODE with the functions in sampo.sh, and logging turned off.
# It prints what CODE sends to the client, with CRLF line endings turned into LF,
# and leaves what CODE writes to STDERR in $BATS_TEST_TMPDIR/stderr.
sampo() {
  bash -c 'source "$1"; loggy() { :; }; eval "$2"' sampo "$SAMPO_SH" "$1" 2> "$BATS_TEST_TMPDIR/stderr" 3>&- \
    | tr -d '\r'
}

# body prints the part of a response that follows its headers
body() {
  sed '1,/^$/d'
}

# script NAME makes an executable script called NAME from STDIN, and prints its path
script() {
  cat > "$BATS_TEST_TMPDIR/$1"
  chmod 755 "$BATS_TEST_TMPDIR/$1"
  echo "$BATS_TEST_TMPDIR/$1"
}

@test "send_response sends each line of the body as it is, even a last line without a newline" {
  run sampo "send_response 200 < <(printf '  indented\n\ttabbed \nno newline')"
  assert_success
  assert_line --index 0 'HTTP/1.0 200 OK'
  assert_equal "$(body <<< "$output")" $'  indented\n\ttabbed \nno newline'
}

@test "send_response sends nothing after the headers of a HEAD response, and stops there" {
  run sampo "REQUEST_METHOD=HEAD; send_response 200 <<< 'the body'; echo 'after send_response'"
  assert_success
  assert_line --index 0 'HTTP/1.0 200 OK'
  refute_line 'the body'
  refute_line 'after send_response'
}

@test "allowed_methods lists each method once, HEAD after GET, and OPTIONS" {
  run sampo "ALLOWED_METHODS=(GET POST GET DELETE); allowed_methods"
  assert_output 'GET,HEAD,POST,DELETE,OPTIONS'
  run sampo "ALLOWED_METHODS=(POST); allowed_methods"
  assert_output 'POST,OPTIONS'
}

@test "run_cgi_script sends the status and headers the script starts with, then the rest of its output" {
  created=$(script created.sh << 'EOF'
#!/usr/bin/env bash
echo "Status: 201 Created"
echo "Content-Type: application/json"
echo "Location: /things/1"
echo
echo "{\"method\": \"$REQUEST_METHOD\", \"body\": \"$(cat)\"}"
echo "a message for the log" >&2
EOF
)
  run sampo "export REQUEST_METHOD=POST REQUEST_BODY=hello; run_cgi_script '$created' /things"
  assert_success
  assert_line --index 0 'HTTP/1.0 201 Created'
  assert_line 'Content-Type: application/json'
  assert_line 'Location: /things/1'
  assert_equal "$(body <<< "$output")" '{"method": "POST", "body": "hello"}'
  # STDERR goes to sampo's STDERR, and not to the client
  refute_output --partial 'a message for the log'
  assert grep -q 'a message for the log' "$BATS_TEST_TMPDIR/stderr"
}

@test "run_cgi_script sends the script's output byte for byte, so a Content-Length it sends stays right" {
  two_lines=$(script two_lines.sh << 'EOF'
#!/bin/sh
echo "Content-Length: 17"
echo
printf 'line one\nline two'
EOF
)
  bash -c 'source "$1"; loggy() { :; }; run_cgi_script "$2" /two_lines' sampo "$SAMPO_SH" "$two_lines" \
    > "$BATS_TEST_TMPDIR/response" 3>&-
  # the body follows the blank line (CRLF) that ends the headers
  sed '1,/^\r$/d' "$BATS_TEST_TMPDIR/response" > "$BATS_TEST_TMPDIR/body"
  printf 'line one\nline two' > "$BATS_TEST_TMPDIR/expected"
  assert cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/body"
}

@test "run_cgi_script answers 200 when the script sends no status" {
  ok=$(script ok.sh << 'EOF'
#!/bin/sh
echo
echo "just a body"
EOF
)
  run sampo "run_cgi_script '$ok' /ok"
  assert_line --index 0 'HTTP/1.0 200 OK'
  assert_equal "$(body <<< "$output")" 'just a body'
}

@test "run_cgi_script answers 500 when the script doesn't start with headers" {
  plain=$(script plain.sh << 'EOF'
#!/bin/sh
echo "hello"
EOF
)
  run sampo "run_cgi_script '$plain' /plain"
  assert_line --index 0 'HTTP/1.0 500 Internal_Server_Error'
  assert_line "plain.sh sent 'hello' where a header should be"
}

@test "run_cgi_script answers 500 when the script ends before the blank line after its headers" {
  short=$(script short.sh << 'EOF'
#!/bin/sh
echo "Content-Type: text/plain"
EOF
)
  run sampo "run_cgi_script '$short' /short"
  assert_line --index 0 'HTTP/1.0 500 Internal_Server_Error'
  assert_line "short.sh ended before the blank line that ends its headers"
  refute_line 'Content-Type: text/plain'
}

@test "run_cgi_script answers 500 for a status it doesn't know, without evaluating it" {
  unknown=$(script unknown.sh << 'EOF'
#!/bin/sh
echo "Status: 299 Unheard Of"
echo
EOF
)
  run sampo "run_cgi_script '$unknown' /unknown"
  assert_line --index 0 'HTTP/1.0 500 Internal_Server_Error'
  assert_line "unknown.sh sent an unknown status: 299 Unheard Of"

  sneaky=$(script sneaky.sh << EOF
#!/bin/sh
echo 'Status: x[\$(touch $BATS_TEST_TMPDIR/pwned)]'
echo
EOF
)
  run sampo "run_cgi_script '$sneaky' /sneaky"
  assert_line --index 0 'HTTP/1.0 500 Internal_Server_Error'
  assert [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "run_cgi_script stops the script after the headers of a HEAD response" {
  slow=$(script slow.sh << EOF
#!/bin/sh
echo "Content-Type: text/plain"
echo
echo "a body HEAD must not get"
echo \$\$ > $BATS_TEST_TMPDIR/slow.pid
exec sleep 30
EOF
)
  SECONDS=0
  run sampo "REQUEST_METHOD=HEAD; run_cgi_script '$slow' /slow"
  assert_success
  assert_line --index 0 'HTTP/1.0 200 OK'
  assert_line 'Content-Type: text/plain'
  refute_line 'a body HEAD must not get'
  [ "$SECONDS" -lt 10 ]
  # the script (by now, sleep) was stopped, and doesn't run on for 30 seconds
  stopped() {
    [ -s "$BATS_TEST_TMPDIR/slow.pid" ] && ! kill -0 "$(cat "$BATS_TEST_TMPDIR/slow.pid")" 2> /dev/null
  }
  for _ in $(seq 20); do stopped && break; sleep 0.1; done
  assert stopped
}
