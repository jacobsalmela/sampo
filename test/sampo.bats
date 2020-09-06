#!/usr/bin/env bats
PORT=1042

test_curl(){
  /usr/bin/curl -s "$1" | sed "s/$(printf '\r')\$//"
}

@test "echo endpoint" {
  run test_curl http://localhost:$PORT/echo/luohi
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "luohi" ]
}

@test "issue endpoint" {
  run test_curl http://localhost:$PORT/issue
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "Welcome to" ]]
}

@test "root endpoint" {
  run test_curl http://localhost:$PORT/root
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "total" ]]
}

@test "example endpoint" {
  run test_curl http://localhost:$PORT/example
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "This is an example" ]]
}

@test "no endpoint" {
  run test_curl http://localhost:$PORT/
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "/" ]]
}
