#!/usr/bin/env bash
#
# pubsub.sh: a tiny publish/subscribe app for sampo that uses GET, POST, PUT and DELETE
#
#   GET    /topics         list topics: NAME<tab>SUBSCRIBERS<tab>DESCRIPTION
#   PUT    /topics/NAME    create topic NAME (201) or update it (200); the body is its description
#   POST   /topics/NAME    publish the body to everyone subscribed to NAME (202)
#   GET    /topics/NAME    subscribe: stream NAME's messages, a line at a time, until NAME is deleted
#   DELETE /topics/NAME    delete NAME (204), which also ends its subscribers' streams
#
# sampo sources this file, so each function is an in-process handler: it can read
# REQUEST_BODY, call append_header, send_response and respond, and it sends one response.
# Each handler takes the topic name as its last argument, so it can be wired to a
# match_uri capture group or to a path segment.
#
# Each topic is a directory under PUBSUB_DIR, and each subscriber is a FIFO in it named
# after the PID of the sampo process streaming to that subscriber.  Publishing writes to
# every FIFO, so messages arrive right away; nothing is stored.

PUBSUB_DIR="${PUBSUB_DIR:-${TMPDIR:-/tmp}/sampo-pubsub}"

# reply() sends a one-line plain text response and ends the request
reply() {
  append_header "Content-Type" "text/plain"
  send_response "$1" <<< "$2"
  exit 0
}

# use_topic() validates a topic name and sets TOPIC and TOPIC_DIR
use_topic() {
  TOPIC="${1:-}"
  [[ "$TOPIC" =~ ^[A-Za-z0-9_-]+$ ]] || reply 400 "invalid topic name: $TOPIC"
  TOPIC_DIR="$PUBSUB_DIR/$TOPIC"
}

# live_subscribers() prints the FIFO of each subscriber to TOPIC_DIR,
# removing the FIFOs of subscribers that disconnected without cleaning up
live_subscribers() {
  local fifo pid
  for fifo in "$TOPIC_DIR"/*.fifo; do
    [[ -p "$fifo" ]] || continue
    pid="${fifo##*/}"
    if kill -0 "${pid%.fifo}" 2>/dev/null; then
      printf '%s\n' "$fifo"
    else
      rm -f "$fifo"
    fi
  done
}

# topic_list() answers GET /topics
topic_list() {
  mkdir -p "$PUBSUB_DIR"
  append_header "Content-Type" "text/plain"
  send_response 200 < <(
    for TOPIC_DIR in "$PUBSUB_DIR"/*/; do
      TOPIC_DIR="${TOPIC_DIR%/}"
      [[ -d "$TOPIC_DIR" ]] || continue
      description=""
      if [[ -f "$TOPIC_DIR/description" ]]; then
        IFS= read -r description < "$TOPIC_DIR/description" || true
      fi
      printf '%s\t%d\t%s\n' "${TOPIC_DIR##*/}" "$(live_subscribers | wc -l)" "$description"
    done
  )
}

# topic_create() answers PUT /topics/NAME
topic_create() {
  use_topic "${@: -1}"
  mkdir -p "$PUBSUB_DIR"
  local code=200
  if mkdir "$TOPIC_DIR" 2>/dev/null; then
    code=201
    append_header "Location" "/topics/$TOPIC"
  fi
  [[ -d "$TOPIC_DIR" ]] || reply 500 "could not create topic $TOPIC"
  printf '%s\n' "$REQUEST_BODY" > "$TOPIC_DIR/description"
  if [[ $code -eq 201 ]]; then
    reply 201 "created topic $TOPIC"
  fi
  reply 200 "updated topic $TOPIC"
}

# topic_publish() answers POST /topics/NAME
topic_publish() {
  use_topic "${@: -1}"
  [[ -d "$TOPIC_DIR" ]] || reply 404 "no such topic: $TOPIC"
  [[ -n "$REQUEST_BODY" ]] || reply 400 "nothing to publish: send the message as the request body"
  local message fifo count=0 nl=$'\n'
  # drop carriage returns and the final newline, then start every line with '>'
  # so that a message can never be mistaken for the end-of-stream line
  message="${REQUEST_BODY//$'\r'/}"
  # (not ${message%"$nl"}: bash takes time quadratic in the length to try that on a long message)
  if [[ "${message: -1}" == "$nl" ]]; then
    message="${message:0:${#message}-1}"
  fi
  message=">${message//"$nl"/$nl>}"
  while IFS= read -r fifo; do
    # opening read-write never waits, even if the subscriber is on its way out
    if printf '%s\n' "$message" 1<>"$fifo"; then
      count=$((count + 1))
    fi
  done < <(live_subscribers)
  reply 202 "published to $count subscriber(s) of $TOPIC"
}

# topic_subscribe() answers GET /topics/NAME by streaming the topic's messages
topic_subscribe() {
  use_topic "${@: -1}"
  [[ -d "$TOPIC_DIR" ]] || reply 404 "no such topic: $TOPIC"
  local line
  PUBSUB_FIFO="$TOPIC_DIR/$$.fifo"
  mkfifo "$PUBSUB_FIFO" || reply 500 "could not subscribe to $TOPIC"
  trap 'rm -f "$PUBSUB_FIFO"' EXIT
  # read-write, so the open does not wait for a publisher and reads never hit end-of-file
  exec 3<>"$PUBSUB_FIFO"

  # send the status line and headers now; each message then goes out as it arrives
  append_header "Content-Type" "text/plain"
  append_header "Cache-Control" "no-cache"
  send_response 200 < /dev/null
  while IFS= read -r -u 3 line; do
    # any line that does not start with '>' means the topic was deleted
    [[ "$line" == ">"* ]] || break
    respond "${line#>}"
  done
  exit 0
}

# topic_delete() answers DELETE /topics/NAME
topic_delete() {
  use_topic "${@: -1}"
  [[ -d "$TOPIC_DIR" ]] || reply 404 "no such topic: $TOPIC"
  local fifo
  while IFS= read -r fifo; do
    printf 'deleted\n' 1<>"$fifo"
  done < <(live_subscribers)
  rm -rf "$TOPIC_DIR"
  send_response 204 < /dev/null
  exit 0
}
