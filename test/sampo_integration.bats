#!/usr/bin/env bats
# bats file_tags=integration

# These integration tests ensure the API is responding as expected.
# This emulates how a client would interact with the API.

setup() {
  # load the supplemental libraries
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  load 'test_helper/bats-file/load'
}

test_curl(){
  /usr/bin/curl -s "$1" | sed "s/$(printf '\r')\$//"
}

test_curl_with_status_code(){
  /usr/bin/curl -s -o /dev/null -w "%{http_code}" "$1" | sed "s/$(printf '\r')\$//"
}

test_valid_json(){
  jq -r "$1"
}

@test "test that the 'jsonsimple' endpoint responds with expected data" {
  run test_curl http://localhost:${PORT:-1042}/jsonsimple
    assert_success
    assert_output --partial '"bash_version":'
}

@test "test that the 'jsonsimple' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/jsonsimple
    assert_success
    assert_output '200'
}

@test "test that the 'jsonlist' endpoint responds with expected data" {
  run test_curl http://localhost:${PORT:-1042}/jsonlist
    assert_success
    assert_output --partial '"shellopts": ['
}

@test "test that the 'jsonlist' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/jsonlist
    assert_success
    assert_output '200'
}

@test "test that the 'jsoncomplex' endpoint responds with expected data" {
  run test_curl http://localhost:${PORT:-1042}/jsoncomplex
    assert_success
    assert_output --partial '"/etc": {'
}

@test "test that the 'jsoncomplex' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/jsoncomplex
    assert_success
    assert_output '200'
}

@test "test that the 'file' endpoint responds with expected data" {
  run test_curl http://localhost:${PORT:-1042}/file//etc/resolv.conf
  assert_success
  assert_output --partial 'nameserver'
}

@test "test that the 'file' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/file//etc/resolv.conf
    assert_success
    assert_output '200'
}

@test "test that the 'file' endpoint keeps indentation and a last line without a newline" {
  # the server reads the fixture by its absolute path on the host
  # ./build.sh -d mounts test/fixtures at the same path in the container
  local fixture="${BATS_TEST_DIRNAME}/fixtures/indented_no_trailing_newline.txt"
  local expected=$'    indented line\n\ttab-indented line\nlast line without newline'
  # the fixture must stay byte for byte: trimming its indentation or adding a final newline would hide the bug
  assert_files_equal "$fixture" <(printf '%s' "$expected")
  run test_curl "http://localhost:${PORT:-1042}/file/${fixture}"
  assert_success
  assert_output "$expected"
}

@test "test that the 'dir' endpoint responds with expected data" {
  run test_curl http://localhost:${PORT:-1042}/dir//
  assert_success
  assert_output --partial 'drwxr-xr-x'
}

@test "test that the 'dir' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/dir//
    assert_success
    assert_output '200'
}

@test "test that the 'example' endpoint responds with expected data" {
  run test_curl http://localhost:${PORT:-1042}/example
  assert_success
  assert_output --partial 'This is an example of an external script.'
}

@test "test that the 'example' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/example
    assert_success
    assert_output '200'
}

@test "test that the '/' endpoint responds with a list of endpoints and the functions they run" {
  run test_curl http://localhost:${PORT:-1042}/
  assert_success
  assert_output '/:list_endpoints
/dir/:serve_dir_with_ls
/example:run_external_script
/file/:serve_file
/jsoncomplex:run_external_script
/jsonlist:run_external_script
/jsonsimple:run_external_script'
}

@test "test that the '/' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/
    assert_success
    assert_output '200'
}
