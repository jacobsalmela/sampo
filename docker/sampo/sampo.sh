#!/usr/bin/env bash
#
# A RESTful API server written in bash and running on Kubernetes
#
# See LICENSE for licensing information.
#
# Original author: Avleen Vig, 2012
# Reworked by:     Josh Cartwright, 2012
# Revamped by:     Jacob Salmela, Copyright (C) 2020 <me@jacobsalmela.com> (sampo)
#
# set -euo pipefail
# -e exit any non-zero exit code
# -u exit on any undefined variable
# -o ensure pipelines (e.g. cmd | othercmd) return a non-zero status if any of the commands fail, rather than returning the exit status of the last command in the pipeline.
# set -x # uncomment for debug mode or call bash -x sampo.sh

# This variable is useful if we ever want to use the name of the app anywhere in the code
readonly APP=sampo

readonly VERSION=1.0.0

# Get the full directory name of the script no matter where it is being called from
readonly WDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Set a config location depending where we are running from
# Simple check to see if we're likely in a container
readonly CONTAINER_CHECK="/proc/1/cgroup"

# Useful logging in the same dir as the script
# set to readonly--Don't let the path be changed
readonly LOG_FILE="$WDIR/$(basename "${0%.*}").log"

# If the file does not exist,
if [[ ! -f "$CONTAINER_CHECK" ]] || [[ "$(cat $CONTAINER_CHECK)" == '/' ]]; then
  # We might be on macOS or some other Darwin-like system that doesn't use /proc
  readonly CONFIG="$WDIR/$APP.conf"

  # Log to stdout and to a log file if we're not in a container
  log() { echo -e "$*" | tee -a "$LOG_FILE" >&2 ; }

else
  # Otherwise, we're probably in a container, so source it from where the kube deployment places it
  readonly CONFIG="/conf/$APP.conf"

  # We can just log to STDOUT in a container
  log() { echo -e "$*"; }
fi

# Get the current date
# For HTTP/1.1 it must be in the format defined in RFC 1123
# Example: Date: Tue, 01 Sep 2020 10:35:28 UTC
DATE=$(date +"%a, %d %b %Y %H:%M:%S %Z")

# HTTP/2.0 could be used, but technically, we'd need to send frames in a specific way
# For the MVP of this software, 1.1 will suffice.
readonly HTTP_VERSION="HTTP/1.1"

# For the MVP, just accept plaintext
readonly ACCEPT_TYPE="text/plain"

# Just use english for the MVP
readonly ACCEPT_LANG="en-US"


# A function to receive data from the client
receive() {
  log "REQUEST: " "$@" >&2;
}


# A function to send data back to the client
# This is the response from the API
respond() {
  log "RESPONSE: " "$@" >&2; printf '%s\r\n' "$*";
}


# A function to show warning messages
warn() {
  log "WARNING:" "$@" >&2;
}


# HTTP headers to return to the client
# These can be seen easily with curl -i
# declare these as an array so we can loop through it later or append any arbitrary headers we want using append_header()
declare -a RESPONSE_HEADERS=(
  "Date: $DATE"
  "Version: $HTTP_VERSION"
  # The Accept request-header field can be used to specify certain media types which are acceptable for the response
  "Accept: $ACCEPT_TYPE"
  # The Accept-Language request-header field is similar to Accept,
  # but restricts the set of natural languages that are preferred as a response to the request
  "Accept-Language: $ACCEPT_LANG"
  # The Server response-header field contains information about the software used by the origin server to handle the request.
  # The field can contain multiple product tokens (section 3.8) and comments identifying the server and any significant subproducts.
  # The product tokens are listed in order of their significance for identifying the application.
  "Server: $APP/$VERSION"
)


append_header() {
  # Add an arbitrary response to the simple header defined in RESPONSE_HEADERS
  local field_definition="$1"
  local value="$2"
  # Example: we may want to add a Content-Type
  # call it as a shell command: append_header "Content-Type" "$CONTENT_TYPE"
  # This exact example is used when we return a file by first checking its type
  RESPONSE_HEADERS+=("$field_definition: $value")
}


# https://tools.ietf.org/html/rfc7231
# Reponse codes
# Some codes are added but commented out for use later
declare -a RESPONSE_CODE=(
  # Information
  [100]="Continue"
  [101]="Switching Protocols"
  # Successful
  [200]="OK"
  [201]="Created"
  [202]="Accepted"
  [203]="Non-Authoritative Information"
  [204]="No Content"
  [205]="Reset Connection"
  # Redirection
  [300]="Multiple Choices"
  [301]="Moved Permanently"
  [302]="Found"
  [303]="See Other"
  # [304]="Not Modified"
  [305]="Use Proxy"
  [307]="Temporary Redirect"
  # Client error
  [400]="Bad Request"
  # [401]="Unauthorized"
  [402]="Payment Required"
  [403]="Forbidden"
  [404]="Not Found"
  [405]="Method Not Allowed"
  [406]="Not Acceptable"
  [408]="Request Timeout"
  [409]="Conflict"
  [410]="Gone"
  [411]="Length Required"
  # [412]="Precondition Failed"
  [413]="Payload Too Large"
  [414]="URI Too Long"
  [415]="Unsupported Media Type"
  # [416]="Range Not Satisfiable"
  [417]="Expectation Failed"
  # [418]="I'm a teapot"
  # [421]="Misdirected Request"
  # [422]="Unprocessable Entity"
  # [423]="Locked"
  # [424]="Fail"
  # [425]="Too Early"
  [426]="Upgrade Required"
  # [428]="Precondition Required"
  # [429]="Too Many Requests"
  # [431]="Request Header Fields Too Large"
  # [451]="Unavailable For Legal Reasons"
  # Server error
  [500]="Internal Server Error"
  [501]="Not Implemented"
  [502]="Bad Gateway"
  [503]="Service Unavailable"
  [504]="Gateway Timeout"
  [505]="HTTP Version Not Supported"
  # [506]="Variant Also Negotiates"
  # [507]="Insufficient Storage"
  # [508]="Loop Detected"
  # [510]="Not Extended"
  # [511]="Network Authentication Required"
)


send_response() {
  # This is the main function that sends a response back to the client when they make an API call
  # The first argument is the return code we need to send
  local code=$1
  # Send a response code and the text from the array above
  # This will return the following as the first line:
  # HTTP/1.1 200 OK
  respond "$HTTP_VERSION $code ${RESPONSE_CODE[$code]}"
  # Then, for each line in our response headers, which contains our pre-defined set:
  #     "Date: $DATE"
  #     "Version: $HTTP_VERSION"
  #     "Accept: $ACCEPT_TYPE"
  #     "Accept-Language: $ACCEPT_LANG"
  #     "Server: $APP/$VERSION"
  # as well as any arbitrary ones we add using append_header()
  for header in "${RESPONSE_HEADERS[@]}"; do
    # send the line to the client
    respond "$header"
  done
  # send a blank line
  respond

  #
  while read -r LINE; do
    respond "$LINE"
  done
}


fail_with() {
  # If we need to fail, we can fail with a specific code
  local code="$1"
  send_response "$code" <<< "$code ${RESPONSE_CODE[$code]}"
  exit 0
}


serve_file() {
  local filename="$1"

  # Get the content type of the file so we can return it to the client
  read -r CONTENT_TYPE < <(file -b --mime-type "$filename")

  # Append it to the array, RESPONSE_HEADERS
  append_header "Content-Type" "$CONTENT_TYPE";

  # Also get the length so that can be returned as well
  read -r CONTENT_LENGTH < <(stat -c'%s' "$filename")

  # Append this as well to the array, RESPONSE_HEADERS
  append_header "Content-Length" "$CONTENT_LENGTH"

  send_response 200 < "$filename"
}


serve_dir_with_ls()
{
  local dir=$1

  # The output from the 'ls' command is just text, so set that here
  append_header "Content-Type" "text/plain"

  # Send back the listing with a 200 return code
  send_response 200 < <(ls -la "$dir")
}


match_uri() {
  local regex="$1"
  # shift to the next parameter
  shift

  # if the REQUEST_URI matches the regex passed in as the first argument,
  if [[ $REQUEST_URI =~ $regex ]]; then
    # the matched part of the REQUEST_URI above is stored in the BASH_REMATCH array
    "$@" "${BASH_REMATCH[@]}"
  fi
}


list_functions() {
  # This lists the names of all the defined functions
  # By default this is called when you don't pass anything to your api call
  # This is useful for debugging, but it illustrates how you can make your
  # own functions here with any shell code you want, and have it callable via an API request
  declare -F | awk '{print $3}'
}


request_headers() {
  # Declare an array for the request headers.  We can use this in a
  # similiar fashion to the RESPONSE_HEADERS by looping over it for whatever we need
  # This isn't used for the MVP but will be useful later
  declare -a REQUEST_HEADERS

  # Parse the payload coming in from the client
  while read -r LINE; do
    LINE=${LINE%%$'\r'}
    receive "$LINE"

    # If we've reached the end of the headers, break.
    [[ -z "$LINE" ]] && break

    # Append each line into the REQUEST_HEADERS array
    REQUEST_HEADERS+=("$LINE")
  done
}


detect_endpoints() {
  # Deine an array to hold all our endpoints
  ENDPOINTS_FUNCTIONS=()
  # search for all the endpoints defined and the functions they call in the config file
  while read -r endpoint
  do
    # get just the endpoint name
    # % * here means remove the string from the end of the variable's contents
    # (whatever is first before the whitespace)
    e="${endpoint% *}"

    # get just the function name
    # ##* means remove the largest string from the beginning of the variable's contents
    # we're matching on whitespace
    f="${endpoint##* }"

    # Append it to the ENDPOINTS_FUNCTIONS array,
    # So we have a hacky "dictionary" of an endpoint and it's associated function that it calls
    ENDPOINTS_FUNCTIONS+=("$e:$f")

  # seach for match_uri lines in the config file
  # and put the endpoint name and the function it calls into an array
  done  < <(awk '/^match_uri/ {print $2, $3}' "$CONFIG" | tr -dc '[:alnum:][:space:]/_\n\r' | sort)
}


list_endpoints() {
  # Lists all configured endpoints and the functions they call from sampo.conf
  # By default, this is tied to the / endpoint
  append_header "Content-Type" "text/plain"

  send_response 200 < <(printf '%s\n' "${ENDPOINTS_FUNCTIONS[@]}")
}


does_endpoint_exist() {
  # Check if the endpoint the user requested actually exists
  detect_endpoints

  # for endpoint in "${ENDPOINTS_FUNCTIONS[@]}"
  # do
  #   # key (endpoint)
  #   endpoint="${endpoint%%:*}"
  #
  #   # Create an array of just
  #   ENDPOINTS+=("$endpoint")
  # done
  #
  # if [[ "${REQUEST_URI}" =~ ${ENDPOINTS[*]} ]]; then
  #   echo endpoint found
  # else
  #   fail_with 405
  # fi
}


run_external_script() {
  # Runs an arbitrary shell script located somewhere else
  # This will be the best way to extend this MVP by adding your own scripts
  script_to_run="$1"
  send_response 200 < <(bash $script_to_run)
}


listen_for_requests() {
  # This is the main function that provides listens for requests from the client
  # It fomats the request appropriately and saves it into vars for use in other functions

  # Read in the request from the client
  read -r LINE || fail_with 400

  # strip trailing CR
  LINE=${LINE%%$'\r'}

  # The client's request comes in looking like this (so parse them out into variables)
  #       GET            /echo/hi    HTTP/1.1
  read -r REQUEST_METHOD REQUEST_URI REQUEST_HTTP_VERSION <<<"$LINE"

  # If any of the below are zero values, fail_with 400 as it may not be a proper request
  if [[ -z "$REQUEST_METHOD" ]] || [[ -z "$REQUEST_URI" ]] || [[ -z "$REQUEST_HTTP_VERSION" ]]; then
    fail_with 400
  fi

  # if [[ "$REQUEST_METHOD" == "GET" ]]; then
  #   :
  # elif [[ "$REQUEST_METHOD" == "POST" ]]; then
  #   :
  # elif [[ "$REQUEST_METHOD" == "PUT" ]]; then
  #   :
  # elif [[ "$REQUEST_METHOD" == "DELETE" ]]; then
  #   :
  # else
  #   :
  # fi

  does_endpoint_exist

  receive "$LINE"
}


listen_for_requests

# shellcheck source=/dev/null
# import the config file
source "$CONFIG"
