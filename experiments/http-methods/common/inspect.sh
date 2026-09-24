#!/usr/bin/env bash
# inspect.sh: shows what an external script gets from sampo for a request.
# The method and body details arrive in the environment, as they would for a CGI script,
# and the request body arrives on STDIN.
set -e
set -u
set -o pipefail

body="$(cat)"
echo "method: ${REQUEST_METHOD:-}"
echo "content type: ${CONTENT_TYPE:-}"
echo "content length: ${CONTENT_LENGTH:-}"
echo "body: $body"
