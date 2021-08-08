#!/usr/bin/env bats
load '../vars'

test_curl(){
  /usr/bin/curl -s "$1" | sed "s/$(printf '\r')\$//"
}

@test "test /echo endpoint" {
  run test_curl http://localhost:$LOCAL_PORT/echo/luohi
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "luohi" ]
}

@test "test /issue endpoint" {
  run test_curl http://localhost:$LOCAL_PORT/issue
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "Welcome to" ]]
}

@test "test /root endpoint" {
  run test_curl http://localhost:$LOCAL_PORT/root
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "total" ]]
}

@test "test /example endpoint" {
  run test_curl http://localhost:$LOCAL_PORT/example
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "This is an example" ]]
}

@test "test no endpoint" {
  run test_curl http://localhost:$LOCAL_PORT/
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "/" ]]
}
