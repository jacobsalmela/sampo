#!/usr/bin/env bash
#
# sampo: A RESTful API server written in bash that serves up any of your arbitrary shell scripts (or anything else)
#
# See LICENSE for licensing information.
#
# Original author: Avleen Vig, 2012
# Reworked by:     Josh Cartwright, 2012
# Revamped by:     Jacob Salmela, Copyright (C) 2020 <me@jacobsalmela.com> (sampo)
#
set -eE
set -u
set -o functrace
set -o pipefail

# -------------------------------------------
# Variables
# -------------------------------------------
# This variable is useful if we ever want to use the name of the app anywhere in the code
readonly APP=sampo
readonly VERSION=1.0.0
readonly FUNDING="https://github.com/sponsors/jacobsalmela/"
# Get the current date
# For HTTP/1.1 it must be in the format defined in RFC 1123
# Example: Tue, 01 Sep 2020 10:35:28 UTC
DATE=""
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
readonly DATE

# Get the full directory name of the script no matter where it is being called from
DIR=""
DIR="$( dirname "${BASH_SOURCE[0]}" )"
readonly DIR
LOG_FILE="$DIR/$APP.log"
readonly LOG_FILE

# Since the software does not yet adhere to the HTTP spec completely, HTTP/1.0 is used
# some clients may even need to be told to explicitly use HTTP/0.9 
readonly HTTP_VERSION="HTTP/1.0"
readonly ACCEPT_TYPE="text/plain"
readonly ACCEPT_LANG="en-US"

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

# Reponse codes from https://tools.ietf.org/html/rfc7231 and the RFCs that followed it
# Scripts run with run_cgi_script() can answer with any of them
declare -a RESPONSE_CODE=(
  # Information
  [100]="Continue"
  [101]="Switching_Protocols"
  [200]="OK"
  [201]="Created"
  [202]="Accepted"
  [203]="Non-Authoritative_Information"
  [204]="No_Content"
  [205]="Reset_Connection"
  [206]="Partial_Content"
  # Redirection
  [300]="Multiple_Choices"
  [301]="Moved_Permanently"
  [302]="Found"
  [303]="See_Other"
  [304]="Not_Modified"
  [305]="Use_Proxy"
  [307]="Temporary_Redirect"
  [308]="Permanent_Redirect"
  # Client error
  [400]="Bad_Request"
  [401]="Unauthorized"
  [402]="Payment_Required"
  [403]="Forbidden"
  [404]="Not_Found"
  [405]="Method_Not_Allowed"
  [406]="Not_Acceptable"
  [407]="Proxy_Authentication_Required"
  [408]="Request_Timeout"
  [409]="Conflict"
  [410]="Gone"
  [411]="Length_Required"
  [412]="Precondition_Failed"
  [413]="Payload_Too_Large"
  [414]="URI_Too_Long"
  [415]="Unsupported_Media_Type"
  [416]="Range_Not_Satisfiable"
  [417]="Expectation_Failed"
  [418]="I'm_a_teapot"
  [421]="Misdirected_Request"
  [422]="Unprocessable_Entity"
  [423]="Locked"
  [424]="Failed_Dependency"
  [425]="Too_Early"
  [426]="Upgrade_Required"
  [428]="Precondition_Required"
  [429]="Too_Many_Requests"
  [431]="Request_Header_Fields_Too_Large"
  [451]="Unavailable_For_Legal_Reasons"
  # Server_error
  [500]="Internal_Server_Error"
  [501]="Not_Implemented"
  [502]="Bad_Gateway"
  [503]="Service_Unavailable"
  [504]="Gateway_Timeout"
  [505]="HTTP_Version_Not_Supported"
  [506]="Variant_Also_Negotiates"
  [507]="Insufficient_Storage"
  [508]="Loop_Detected"
  [510]="Not_Extended"
  [511]="Network_Authentication_Required"
)

# The methods of routes that matched the request's path but not its method (see match_uri)
declare -a ALLOWED_METHODS=()

# Check the control groups of the init process, which vary depending on the OS vs. container
readonly CONTAINER_CHECK="/proc/1/cgroup"
readonly CONFIG="$DIR/$APP.conf"

# -------------------------------------------
# Functions
# -------------------------------------------
# container_check() checks to see if the script is running in a container by looking at cgroups
# it also checks if it is running on kubernetes via a variable 
container_check() {
  # /proc/1/cgroup exists on every Linux host, so also require that PID 1's STDOUT is writable
  if [[ -f "$CONTAINER_CHECK" ]] && [[ -w /proc/1/fd/1 ]]; then
    if [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then
      # Check next if running in Kubernetes
      LOGTO="STDOUT"
    else
      # Docker for Mac exposes this variable to both Docker and Kubernetes, so something else may be desired here
      # for now, this just defaults to STDOUT
      LOGTO="STDOUT"
    fi
  else
    LOGTO="FILE"
  fi
}

# die() is used with a trap and shows the current line number and command where the error occurred
die() {
  local lineno="${1}"
  local msg="${2}"
  local retval=$3
  echo "**         **"
  echo "** FAILURE ** ${0} ($retval) at line $lineno: $msg"
  echo "**         **"
}

# loggy() is used to log to STDOUT or a file in extended log format
loggy() {
local elf="${DATE:--} ${REQUEST_HOST:--} ${REQUEST_USER_AGENT:--} ${REQUEST_METHOD:--} ${ENDPOINT:--} ${REQUEST_HTTP_VERSION:--} ${STATUS_CODE:--}"
  case "$LOGTO" in
    "STDOUT") echo -e "${elf} $*" >/proc/1/fd/1;;
    "FILE")   echo -e "${elf} $*" >> "$LOG_FILE";;
    # Fallback to STDOUT if encountered
    *)        echo -e "${elf} $*";;
  esac
}

# debuggy() is used to log to STDOUT or a file for debugging
debuggy() {
  case "$LOGTO" in
    "STDOUT") echo -e "$*" >/proc/1/fd/1;;
    "FILE")   echo -e "$*" >> "$LOG_FILE";;
    *)        echo -e "$*";;
  esac
}

# respond() sends data back to the client. This is the response from the API,
# when used with the other functions, as you can see, it is just a simple printf statement
respond() {
  printf '%s\r\n' "$*";
}

# append_header() is used to add a header to the response
append_header() {
  # Add an arbitrary response to the simple header defined in RESPONSE_HEADERS
  local field_definition="$1"
  local value="$2"
  # Example: we may want to add a Content-Type
  # call it as a shell command: append_header "Content-Type" "$CONTENT_TYPE"
  # This exact example is used when we return a file by first checking its type
  RESPONSE_HEADERS+=("$field_definition: $value")
}

# send_response() is the main function that sends a response back to the client when they make an API call
send_response() {
  # This is the main function that sends a response back to the client when they make an API call
  # The first argument is the return code we need to send
  local code=$1
  # Send a response code and the text from the array above
  # This will return a line in the format:
  # HTTP/1.0 200 OK
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

  # send the body a line at a time, as it arrives, keeping each line as it is,
  # including the last one when it doesn't end with a newline
  # a HEAD request gets everything a GET would, except the body
  if [[ "${REQUEST_METHOD:-}" != "HEAD" ]]; then
    while IFS= read -r LINE || [[ -n "$LINE" ]]; do
      respond "$LINE"
    done
  fi

  # Log the request now that the code has been set
  STATUS_CODE=$code
  loggy ""

  # nothing may follow the headers of a HEAD response, so stop here, even if the handler would go on
  if [[ "${REQUEST_METHOD:-}" == "HEAD" ]]; then
    exit 0
  fi
}


# read_body() reads exactly $1 bytes of the request body into REQUEST_BODY
# LC_ALL=C makes read -N count bytes (like Content-Length does) instead of characters
read_body() {
  local LC_ALL=C
  IFS= read -r -N "$1" REQUEST_BODY || true
}

# fail_with() pseudo-fails the script with a given response code
fail_with() {
  local code="$1"
  send_response "$code" <<< "$code ${RESPONSE_CODE[$code]}"
  exit 0
}

# serve_file() returns the contents of a file on the host to the client
# It also sets the Content-Type and Content-Length headers using file and stat.
# at present, it can only handle simple file paths, without special characters
serve_file() {
  local endpoint="$1"
  local filename="$2"

  if [[ "${SAMPO_DEBUG:=false}" == "true" ]]; then
    debuggy "[$(basename "${BASH_SOURCE[0]}"):${LINENO}:${FUNCNAME[*]:0:${#FUNCNAME[@]}-1}()] serving file: $filename"
  fi

  # Get the content type of the file so we can return it to the client
  read -r CONTENT_TYPE < <(file -b --mime-type "$filename")

  # Append it to the array, RESPONSE_HEADERS
  append_header "Content-Type" "$CONTENT_TYPE";

  # FIXME: Inconsistent results across platforms
  # Also get the length so that can be returned as well
  # read -r CONTENT_LENGTH < <(if ! stat -c%s "$filename"; then stat -f%z "$filename"; fi)

  # Append this as well to the array, RESPONSE_HEADERS
  # append_header "Content-Length" "$CONTENT_LENGTH"
  send_response 200 < "$filename"
}

# serve_dir() returns a listing of a directory on the host to the client
# at present, it can only handle simple file paths, without special characters
serve_dir_with_ls()
{
  local endpoint="$1"
  local dir=$2

  if [[ "${SAMPO_DEBUG:=false}" == "true" ]]; then
    debuggy "[$(basename "${BASH_SOURCE[0]}"):${LINENO}:${FUNCNAME[*]:0:${#FUNCNAME[@]}-1}()] serving dir: $dir"
  fi

  # The output from the 'ls' command is just text, so set that here
  append_header "Content-Type" "text/plain"

  # Send back the listing with a 200 return code
  send_response 200 < <(ls -lha "$dir")
}


# match_uri() matches a URI against a regex and calls a function if it matches
# usage: match_uri [METHOD] REGEX command [args]
# METHOD is GET, POST, PUT or DELETE; a route without one is a GET route, as before
# GET routes also answer HEAD requests (send_response() leaves out the body)
match_uri() {
  local method="GET"
  local request_method="$REQUEST_METHOD"
  if [[ "$1" =~ ^(GET|POST|PUT|DELETE)$ ]]; then
    method="$1"
    shift
  fi
  local regex="$1"
  # shift to the next parameter
  shift
  if [[ "$request_method" == "HEAD" ]]; then
    request_method="GET"
  fi

  if [[ ${SAMPO_DEBUG:=false} == true ]]; then
    debuggy "Matching '$REQUEST_URI' against '$regex' for commands: $* <rematches...> <non-matches...>"
  fi

  # if the REQUEST_URI matches the regex passed in as the first argument,
  if [[ $REQUEST_URI =~ $regex ]]; then
    # the path matches, but this route is for another method: remember it for the Allow header
    # of a 405, or of the answer to OPTIONS
    if [[ "$request_method" != "$method" ]]; then
      ALLOWED_METHODS+=("$method")
      return 0
    fi
    # the matched part of the REQUEST_URI above is stored in the BASH_REMATCH array
    # the unmatched part may comprise path and query parameters: pass them on, too
    local unmatched="${REQUEST_URI#${BASH_REMATCH[0]}}"
    unmatched="${unmatched#/}"
    if [[ ${SAMPO_DEBUG:=false} == true ]]; then
      debuggy "Matched '${BASH_REMATCH[0]}' with rematches '${BASH_REMATCH[*]:1}' and unmatched '$unmatched'"
    fi
    if [ -n "$unmatched" ]; then
      "$@" "${BASH_REMATCH[@]}" "$unmatched"
    else
      "$@" "${BASH_REMATCH[@]}"
    fi
  fi
}


# allowed_methods() prints ALLOWED_METHODS for an Allow header: each method once, with HEAD
# after GET, and OPTIONS, which sampo answers for any route
allowed_methods() {
  local method allowed=""
  for method in "${ALLOWED_METHODS[@]}"; do
    # skip methods that are already listed
    if [[ ",$allowed," == *",$method,"* ]]; then
      continue
    fi
    allowed+="${allowed:+,}$method"
    if [[ "$method" == "GET" ]]; then
      allowed+=",HEAD"
    fi
  done
  echo "${allowed:+$allowed,}OPTIONS"
}


# list_function() lists the names of all the defined functions
list_functions() {
  declare -F | awk '{print $3}'
}

# serve_echo() returns the contents of an arbitrary string to the client
serve_echo() {
  endpoint="$1"
  echo_string="$2"
  if [[ "${SAMPO_DEBUG:=false}" == "true" ]]; then
    debuggy "[$(basename "${BASH_SOURCE[0]}"):${LINENO}:${FUNCNAME[*]:0:${#FUNCNAME[@]}-1}()] echoing: $echo_string"
  fi
  append_header "Content-Type" "text/plain"
  send_response 200 <<< "$echo_string"
}

# detect_endpoints() searches the config file for all the endpoints defined and the functions they call
detect_endpoints() {
  # Deine an array to hold all our endpoints
  ENDPOINTS_FUNCTIONS=()
  ENDPOINTS=()
  # search for all the endpoints defined and the functions they call in the config file
  while read -r method endpoint
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
    ENDPOINTS_FUNCTIONS+=("$method $e:$f")
    # Create an array of just
    ENDPOINTS+=("$e")
  # seach for match_uri lines in the config file
  # and put the endpoint name and the function it calls into an array
  # due to whitespace in the config, check the first field for match_uri
  # remove all non-alphanumeric characters and newlines since they code definitions span multiple lines
  # a route without a method is a GET route
  done  < <(awk '{if ($1 ~ /^match_uri/) { if ($2 !~ /^(GET|POST|PUT|DELETE)$/) $0 = $1 " GET " $2 " " $3; print $2, $3, $4 }}' "$CONFIG" | tr -dc '[:alnum:][:space:]/_\n\r' | sort -k2,2 -k1,1)
  # done < <(awk '/^match_uri/ {print $2, $3}' "$CONFIG" | tr -d '[:alnum:][:space:]/_\n\r' | sort)
}


# list_endpoint() lists all configured endpoints and the functions they call
# By default, this is tied to the / endpoint as a helpful way to get started without a manual
list_endpoints() {
  append_header "Content-Type" "text/plain"

  send_response 200 < <(printf '%s\n' "${ENDPOINTS_FUNCTIONS[@]}")
}


# endpoint_exists() checks if the endpoint exists in the config file
endpoint_exists() {
  detect_endpoints

  # TODO: The regex is tricky here, and needs adjustments
  ENDPOINT=${REQUEST_URI#/}
  ENDPOINT=/${ENDPOINT%%/*}

  # https://stackoverflow.com/a/15394738
  if [[ ${ENDPOINTS[*]} =~ ${ENDPOINT} ]]; then
    # return 0 if the endpoint exists
    return 0
  fi

  if [[ ! ${ENDPOINTS[*]} =~  ${ENDPOINT} ]]; then
    # send a 404 if the endpoint doesn't exist
    send_response 404 < <(echo "$ENDPOINT does not exist.  Is it defined in sampo.conf?")
  fi

}

# script_args() turns the arguments of run_external_script() and run_cgi_script() into
# script_to_run, the script, and args, the arguments to run it with
script_args() {
  script_to_run="$1"
  endpoint="$2"
  shift 2
  args=( "$@" )
  # check last arg
  if [[ "${args[@]:(-1)}" =~ [?] ]]; then
    # convert CGI query parameters to GNU-style CLI options
    # reverse order (--opts then args instead of args?opts)
    cgi="${args[@]:(-1)}"
    args=( "${args[@]:0:${#args[@]}-1}" )
    cgipath="${cgi%%[?]*}"
    args=( "$cgipath" "${args[@]}" )
    IFS=$'&' cgiopts=( ${cgi#$cgipath[?]} )
    IFS=$' \t\n'
    for opt in "${cgiopts[@]}"; do
      key="${opt%%=*}"
      val="${opt#*=}"
      if [ -n "$val" ]; then
        args=( "$val" "${args[@]}" )
      fi
      args=( --$key "${args[@]}" )
    done
  fi
  if [[ "${SAMPO_DEBUG:=false}" == "true" ]]; then
    debuggy "[$(basename "${BASH_SOURCE[0]}"):${LINENO}:${FUNCNAME[*]:0:${#FUNCNAME[@]}-1}()] running external script: $script_to_run ${args[*]}"
  fi
}

# run_external_script() runs an arbitrary shell script located somewhere else
# this is arguably the best feature of sampo, as it allows unlimited extensibility
run_external_script() {
  script_args "$@"
  retval=200
  # the request body, if any, is the script's STDIN
  result="$("${script_to_run}" "${args[@]}" 2>&1 < <(printf '%s' "${REQUEST_BODY:-}"))" || retval=500
  send_response $retval <<< "$result"
}

# run_cgi_script() runs a script like run_external_script() does, except that the script chooses
# the status and headers, and its output reaches the client as the script writes it, byte for byte.
# Like a CGI script, it starts its output with headers, such as "Status: 201" (the status is 200
# without one) or "Content-Type: application/json", and then a blank line; the rest is the body.
# The script's STDERR is not sent to the client.
run_cgi_script() {
  local fd line name value status=200 script_pid
  local -a headers=()
  # a header is a name, a colon and a value; matching the whole line with a regex takes time in
  # proportion to its length, where some ${line%...} expansions take its square
  local header_regex='^([A-Za-z0-9-]+):[[:blank:]]*(.*)$'
  script_args "$@"
  # the request body, if any, is the script's STDIN
  exec {fd}< <(exec "${script_to_run}" "${args[@]}" < <(printf '%s' "${REQUEST_BODY:-}"))
  script_pid=$!
  # stop the script if sampo finishes first: after the headers of a HEAD response, say,
  # or when the client goes away
  # shellcheck disable=SC2064 # the PID is known now
  trap "kill $script_pid 2> /dev/null || true" EXIT

  # read the headers, up to the blank line
  while IFS= read -r -u "$fd" line; do
    if [[ "$line" == *$'\r' ]]; then
      line="${line:0:${#line}-1}"
    fi
    if [[ -z "$line" ]]; then
      # send the status and headers, then the rest of the output as it comes
      RESPONSE_HEADERS+=( "${headers[@]}" )
      send_response "$status" < /dev/null
      cat <&"$fd" || true
      return 0
    fi
    if [[ ! "$line" =~ $header_regex ]]; then
      send_response 500 <<< "${script_to_run##*/} sent '${line:0:100}' where a header should be"
      return 0
    fi
    name="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "${name,,}" == "status" ]]; then
      # check the code before using it as an index: bash evaluates array indexes as math
      if [[ ! "$value" =~ ^([1-5][0-9][0-9])([[:blank:]]|$) ]] || [[ -z "${RESPONSE_CODE[${BASH_REMATCH[1]}]:-}" ]]; then
        send_response 500 <<< "${script_to_run##*/} sent an unknown status: ${value:0:100}"
        return 0
      fi
      status="${BASH_REMATCH[1]}"
    else
      headers+=( "$name: $value" )
    fi
  done
  send_response 500 <<< "${script_to_run##*/} ended before the blank line that ends its headers"
}


# listen_for_requests() listens for requests from the client
# it reads in the request and parses it into three variables that make up the request
# REQUEST_METHOD, REQUEST_URI, and REQUEST_HTTP_VERSION
# it checks the request headers, which can be used in log files or elsewhere, and reads the body
# then, it calls endpoint_exists() to check if the endpoint exists in the config file
# it checks if the script is running in a container
# then it sources sampo.conf to get the user-defined endpoints and functions
# there is a bit of logic to determine if this entire script is being sourced or not
# this allows for re-use of the functions in other scripts and for testing
listen_for_requests() {
  # This is the main function that provides listens for requests from the client
  # It fomats the request appropriately and saves it into vars for use in other functions

  # Read in the request from the client
  read -r LINE || fail_with 400

  # strip trailing CR
  LINE=${LINE%%$'\r'}

  # The client's request comes in looking like this (so parse them out into variables)
  #       GET            /echo/hi    HTTP/1.0
  read -r REQUEST_METHOD REQUEST_URI REQUEST_HTTP_VERSION <<<"$LINE"

  # If any of the below are zero values, fail_with 400 as it may not be a proper request
  if [[ -z "$REQUEST_METHOD" ]] || [[ -z "$REQUEST_URI" ]] || [[ -z "$REQUEST_HTTP_VERSION" ]]; then
    fail_with 400
  fi

  # Declare an array for the request headers.  We can use this in a
  # similiar fashion to the RESPONSE_HEADERS by looping over it for whatever we need
  # This isn't used for the MVP but will be useful later
  declare -a REQUEST_HEADERS

  # Parse the payload coming in from the client
  while read -r LINE; do
    LINE=${LINE%%$'\r'}
    header_key="${LINE%%:*}"
    header_value="${LINE#*: }"

    case "$header_key" in
      [Cc]ontent-[Ll]ength)
        REQUEST_CONTENT_LENGTH="$header_value"
        ;;
      [Cc]ontent-[Tt]ype)
        REQUEST_CONTENT_TYPE="$header_value"
        ;;
      Host)
        REQUEST_HOST="$header_value"
        ;;
      User-Agent)
        REQUEST_USER_AGENT="$header_value"
        ;;
      *)
        ;;
    esac

    # If we've reached the end of the headers, break.
    [[ -z "$LINE" ]] && break

    # Append each line into the REQUEST_HEADERS array
    REQUEST_HEADERS+=("$LINE")
  done

  # Read the request body (sent with POST and PUT) into REQUEST_BODY
  REQUEST_BODY=""
  if [[ -n "${REQUEST_CONTENT_LENGTH:-}" ]]; then
    # validate before doing any math: bash evaluates the contents of variables inside (( ))
    if [[ ! "$REQUEST_CONTENT_LENGTH" =~ ^[0-9]+$ ]]; then
      fail_with 400
    elif [[ ${#REQUEST_CONTENT_LENGTH} -gt 9 ]] || (( 10#$REQUEST_CONTENT_LENGTH > ${SAMPO_MAX_BODY:-1048576} )); then
      fail_with 413
    fi
    read_body "$REQUEST_CONTENT_LENGTH"
  fi

  # now that the whole request has been read, answer with a 404 if the endpoint doesn't exist
  endpoint_exists
  if [[ -n "${STATUS_CODE:-}" ]]; then
    exit 0
  fi

  # Like CGI, hand the method and body details to external scripts through the environment
  export REQUEST_METHOD REQUEST_URI
  export CONTENT_LENGTH="${REQUEST_CONTENT_LENGTH:-0}" CONTENT_TYPE="${REQUEST_CONTENT_TYPE:-}"

  # match_uri() decides which method each route accepts; HEAD and OPTIONS are answered for every route
  if [[ "$REQUEST_METHOD" =~ ^(GET|HEAD|POST|PUT|DELETE|OPTIONS)$ ]]; then
    :  
  else
    send_response 501 < <(echo "$REQUEST_METHOD is invalid or not yet implemented. $FUNDING")
    exit 0
  fi

}


if [[ "$(basename "${0}")" == "sampo.sh" ]]; then

  # Run cleanup function in interrupt
  trap cleanup SIGINT
  # trap on error and print the line number and command
  trap 'die ${BASH_SOURCE[0]}:${LINENO}:${FUNCNAME} "$BASH_COMMAND" $?' ERR

  container_check

  if [[ "${SAMPO_DEBUG:=false}" == "true" ]]; then
    debuggy "\$SAMPO_DEBUG is set to true.  This will cause a lot of output."
  fi

  listen_for_requests
  # import the config file
  # the endpoints should be deined in the config file
  # when a client queries sampo, the request is checked against what is defined there
  #shellcheck source=sampo.conf
  source "${CONFIG}"

  # no route answered: the path only has routes for other methods, or no route at all (404)
  # OPTIONS lists the methods the path does have, and any other method gets a 405 that lists them
  if [[ -z "${STATUS_CODE:-}" ]]; then
    if [[ ${#ALLOWED_METHODS[@]} -gt 0 ]]; then
      append_header "Allow" "$(allowed_methods)"
      if [[ "$REQUEST_METHOD" == "OPTIONS" ]]; then
        send_response 204 < /dev/null
        exit 0
      fi
      fail_with 405
    fi
    fail_with 404
  fi
else
  # this script is being sourced so do not run the functions
  # this helps with unit tests and/or other scripts needing to utilize the functions defined here
  # loggy  "$(basename "${BASH_SOURCE[0]}") sourced by $(basename "${0}")"
  :
fi
