#!/usr/bin/env bash
set -e
set -u
set -o pipefail

# sampo runs this script for POST /example (see sampo.conf)
# The request body arrives on STDIN, and details about the request in the environment
body="$(cat)"

echo -e "This is an example of an external script that receives a request body."
echo "method: ${REQUEST_METHOD:-}"
echo "content type: ${CONTENT_TYPE:-}"
echo "content length: ${CONTENT_LENGTH:-}"
echo "body: $body"
