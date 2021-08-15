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
  # Otherwise, we're probably in a container, so source from sampo/sampo.conf
  readonly CONFIG="/$APP/$APP.conf"

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


# receive() receives data from the client
receive() {
  log
  log "=====> REQUEST: " "$@" >&2;
  log
}


# respond() sends data back to the client.  This is the response from the API
respond() {
  log "<==   RESPONSE: " "$@" >&2; printf '%s\r\n' "$*"
}


# warn() shows warning messages
warn() {
  log "WARNING:" "$@" >&2
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


# append_header() adds arbitrary response headers to the API's response
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

# send_response() sends a response back to the client when they make an API call
send_response() {
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
    # send each header to the client
    respond "$header"
  done
  # send a blank line
  respond

  # then send the response from the output
  # -r, do not allow backslashes to escape any characters
  while read -r LINE; do
    respond "$LINE"
  done
}


# serve_echo() replies an echo of arbitrary text
serve_echo() {
   append_header "Content-Type" "text/plain"
   send_response 200 <<< "$2"
}


serve_file() {
  local filename="$1"

  # Get the content type of the file and save it to a variable so we can return it to the client in a header
  read -r CONTENT_TYPE < <(file -b --mime-type "$filename")

  # Append it to the array, RESPONSE_HEADERS
  append_header "Content-Type" "$CONTENT_TYPE";

  # Also get the length so that can be returned as well
  read -r CONTENT_LENGTH < <(stat -c'%s' "$filename")

  # Do the same for the file's size, RESPONSE_HEADERS
  append_header "Content-Length" "$CONTENT_LENGTH"

  # Send the content of the file
  send_response 200 < "$filename"
}


# serve_dir_with_ls() does a long listing on a directory passed to it
serve_dir_with_ls()
{
  local dir
  readonly dir=$1
  # The output from the 'ls' command is just text, so set that here
  append_header "Content-Type" "text/plain"

  # Send back the long listing with a 200 return code
  send_response 200 < <(ls -la "$dir")
}

# uri_decode() decodes URL-encoded strings for easier handling in shell
uri_decode() {
  # Taken from https://stackoverflow.com/a/6265305/566849
  echo -e "$(sed 's/+/ /g;s/%\(..\)/\\x\1/g;')"
}


# match_uri() matches the endpoints being requested by the client using a regular expression
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

# list_functions() returns a list of all the available functions (API endpoints) provided in this script
# by default, this is sent when you don't request the root endpoint of the API (http://localhost:PORT/)
list_functions() {
  # This lists the names of all the defined functions
  # This is useful for debugging, but it illustrates how you can make your
  # own functions here with any shell code you want, and have it callable via an API request
  declare -F | awk '{print $3}'
}

# request_headers() checks the request for any headers and appends them to an array
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


# detect_endpoints() puts all the endpoints into an array
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

# list_endpoints() lists all available endpoints
list_endpoints() {
  # Lists all configured endpoints and the functions they call from sampo.conf
  # By default, this is tied to the / endpoint
  append_header "Content-Type" "text/plain"

  send_response 200 < <(printf '%s\n' "${ENDPOINTS_FUNCTIONS[@]}")
}


# does_endpoint_exist() validates that an endpoint exists, and sends back a 405 (method not allowed)
does_endpoint_exist() {
  # Check if the endpoint the user requested actually exists
  detect_endpoints

  if [[ ${ENDPOINTS_FUNCTIONS[*]} =~ ${REQUEST_URI} ]]; then
    # whatever you want to do when array contains value
    return 0
  fi

  if [[ ! "${ENDPOINTS_FUNCTIONS[*]}" =~ ${REQUEST_URI} ]]; then
      # whatever you want to do when array doesn't contain value
      send_response 404 <<< "404 ${REQUEST_URI} does not exist"
      return 1
  fi

}

# run_external_script() executes an arbitrary shell script
# this is perhaps the most useful portion of this API as it allows you to extend it's capabilities with any existing shell scripts you have
run_external_script() {
  local script_to_run="$1"
  # use process substitution to send the output of the shell script as an api response: https://www.gnu.org/savannah-checkouts/gnu/bash/manual/bash.html#Process-Substitution
  send_response 200 < <(bash "$script_to_run" 2>&1)
}

# listen_for_requests()
listen_for_requests() {
  # This is the main function that provides listens for requests from the client
  # It fomats the request appropriately and saves it into vars for use in other functions

  # Read in the request from the client
  read -r LINE || send_response 400

  # strip trailing CR
  LINE=${LINE%%$'\r'}

  # The client's request comes in looking like this (so parse them out into variables)
  #       GET            /echo/hi    HTTP/1.1
  read -r REQUEST_METHOD REQUEST_URI REQUEST_HTTP_VERSION <<<"$LINE"

  # Borrowed from https://github.com/avleen/bashttpd/pull/37/files
  # REQUEST_URI=$(uri_decode <<<"$REQUEST_URI")

  # If any of the below are zero values, fail with 400 as it may not be a proper request
  if [[ -z "$REQUEST_METHOD" ]] \
     || [[ -z "$REQUEST_URI" ]] \
     || [[ -z "$REQUEST_HTTP_VERSION" ]]; then
        send_response 400 <<< "\$REQUEST_METHOD:$REQUEST_METHOD \$REQUEST_URI:$REQUEST_URI \$REQUEST_HTTP_VERSION:$REQUEST_HTTP_VERSION"
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

  # check first if the endpoint exists
  if eval does_endpoint_exist; then
    receive "$LINE"
  fi
}


# Start the API server
listen_for_requests

# shellcheck source=/dev/null
# then import the config file
source "$CONFIG"
