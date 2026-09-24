#!/usr/bin/env bash
set -e
set -u
set -o pipefail

# sampo runs this script with run_cgi_script (see sampo.conf), so it starts its output with headers:
# a Status line when the status isn't 200, any other headers, and then a blank line.
# sampo sends the rest to the client as the script writes it: try curl -N http://localhost:1042/countdown/5
seconds="${1:-}"

if [[ ! "$seconds" =~ ^([0-9]|10)$ ]]; then
  echo "Status: 400"
  echo "Content-Type: text/plain"
  echo
  echo "Count down from 0 to 10 seconds, for example with /countdown/5"
  exit 0
fi

echo "Content-Type: text/plain"
echo
for ((i = seconds; i > 0; i--)); do
  echo "$i"
  sleep 1
done
echo "liftoff"
