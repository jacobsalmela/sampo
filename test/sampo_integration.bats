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

# test_curl [curl options] URL
test_curl(){
  /usr/bin/curl -s "$@" | sed "s/$(printf '\r')\$//"
}

# test_curl_with_status_code [curl options] URL
test_curl_with_status_code(){
  /usr/bin/curl -s -o /dev/null -w "%{http_code}" "$@" | sed "s/$(printf '\r')\$//"
}

test_valid_json(){
  jq -r "$1"
}

@test "test that the 'jsonsimple' endpoint responds with expected data" {
  run test_curl http://localhost:${PORT:-1042}/jsonsimple
    assert_success
    assert_output --partial '"bash_version":'
}

@test "test that the 'jsonsimple' endpoint keeps the script's indentation" {
  run test_curl http://localhost:${PORT:-1042}/jsonsimple
    assert_success
    assert_line --regexp '^    "bash_version":"'
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

@test "test that the 'example' endpoint runs another script for POST, which gets the request body" {
  run test_curl -X POST -H 'Content-Type: text/plain' --data-binary 'héllo ✓' http://localhost:${PORT:-1042}/example
  assert_success
  assert_output 'This is an example of an external script that receives a request body.
method: POST
content type: text/plain
content length: 10
body: héllo ✓'
}

@test "test that the 'example' endpoint returns status code 200 for POST" {
  run test_curl_with_status_code -X POST --data-binary 'hello' http://localhost:${PORT:-1042}/example
    assert_success
    assert_output '200'
}

@test "test that a method an endpoint has no rule for returns status code 405 and lists the ones it has" {
  run test_curl -i -X DELETE http://localhost:${PORT:-1042}/example
  assert_success
  assert_line --index 0 'HTTP/1.0 405 Method_Not_Allowed'
  assert_line 'Allow: GET,HEAD,POST,OPTIONS'
}

@test "test that HEAD gets the status and headers of a GET, and no body" {
  run test_curl -i -X HEAD http://localhost:${PORT:-1042}/example
  assert_success
  assert_line --index 0 'HTTP/1.0 200 OK'
  refute_output --partial 'This is an example of an external script.'
}

@test "test that OPTIONS returns status code 204 and lists the methods an endpoint has" {
  run test_curl -i -X OPTIONS http://localhost:${PORT:-1042}/example
  assert_success
  assert_line --index 0 'HTTP/1.0 204 No_Content'
  assert_line 'Allow: GET,HEAD,POST,OPTIONS'
}

@test "test that OPTIONS for an endpoint that doesn't exist returns status code 404" {
  run test_curl_with_status_code -X OPTIONS http://localhost:${PORT:-1042}/nope
    assert_success
    assert_output '404'
}

@test "test that the 'countdown' endpoint sends all of its script's output" {
  run test_curl http://localhost:${PORT:-1042}/countdown/1
  assert_success
  assert_output '1
liftoff'
}

@test "test that the 'countdown' endpoint streams its script's output as the script writes it" {
  # the countdown takes 3 seconds, but its first line arrives long before that
  run test_curl -N --max-time 1.5 http://localhost:${PORT:-1042}/countdown/3
  assert_success
  assert_line --index 0 '3'
  refute_output --partial 'liftoff'
}

@test "test that a script run with run_cgi_script chooses its status code and headers" {
  run test_curl -i http://localhost:${PORT:-1042}/countdown/eleven
  assert_success
  assert_line --index 0 'HTTP/1.0 400 Bad_Request'
  assert_line 'Content-Type: text/plain'
  assert_line 'Count down from 0 to 10 seconds, for example with /countdown/5'
}

@test "test that HEAD gets the headers of a streaming script without waiting for the rest" {
  run test_curl -i -X HEAD --max-time 5 http://localhost:${PORT:-1042}/countdown/9
  assert_success
  assert_line --index 0 'HTTP/1.0 200 OK'
  assert_line 'Content-Type: text/plain'
  refute_line '9'
}

@test "test that a method sampo doesn't implement returns status code 501" {
  run test_curl_with_status_code -X PATCH http://localhost:${PORT:-1042}/example
    assert_success
    assert_output '501'
}

@test "test that a URI that matches no rule returns status code 404" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/example/nothing-here
    assert_success
    assert_output '404'
}

@test "test that a POST to an endpoint that doesn't exist gets a single 404 response" {
  run test_curl -i -X POST --data-binary 'hello' http://localhost:${PORT:-1042}/nope
  assert_success
  assert_line --index 0 'HTTP/1.0 404 Not_Found'
  refute_line --partial 'HTTP/1.0 501'
}

@test "test that a Content-Length that isn't a number returns status code 400" {
  run test_curl_with_status_code -X POST -H 'Content-Length: 1+1' http://localhost:${PORT:-1042}/example
    assert_success
    assert_output '400'
}

@test "test that a body larger than SAMPO_MAX_BODY returns status code 413" {
  run test_curl_with_status_code -X POST -H 'Content-Length: 99999999999' http://localhost:${PORT:-1042}/example
    assert_success
    assert_output '413'
}

@test "test that the '/' endpoint responds with a list of endpoints, their methods and the functions they run" {
  run test_curl http://localhost:${PORT:-1042}/
  assert_success
  assert_output 'GET /:list_endpoints
GET /countdown/:run_cgi_script
GET /dir/:serve_dir_with_ls
GET /example:run_external_script
POST /example:run_external_script
GET /file/:serve_file
GET /jsoncomplex:run_external_script
GET /jsonlist:run_external_script
GET /jsonsimple:run_external_script'
}

@test "test that the '/' endpoint returns status code 200" {
  run test_curl_with_status_code http://localhost:${PORT:-1042}/
    assert_success
    assert_output '200'
}
