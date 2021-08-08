#!/usr/bin/env bats
load '../vars'

test_curl(){
  /usr/bin/curl -s "$1" | sed "s/$(printf '\r')\$//"
}

@test "test /echo endpoint" {
  run test_curl http://localhost:$PORT/echo/luohi
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "luohi" ]
}

@test "test /hosts endpoint" {
  run test_curl http://localhost:$PORT/hosts
  [ "$status" -eq 0 ]
}

@test "test /root endpoint" {
  run test_curl http://localhost:$PORT/root
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "total" ]]
}

@test "test /example endpoint" {
  run test_curl http://localhost:$PORT/example
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "This is an example" ]]
}

@test "test json list" {
  run test_curl http://localhost:$PORT/jsonlist
  [ "$status" -eq 0 ]
}

@test "test json simple" {
  run test_curl http://localhost:$PORT/jsonsimple
  [ "$status" -eq 0 ]
}

@test "test json complex" {
  run test_curl http://localhost:$PORT/jsoncomplex
  [ "$status" -eq 0 ]
}

@test "test no endpoint" {
  run test_curl http://localhost:$PORT/
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "/" ]]
}
