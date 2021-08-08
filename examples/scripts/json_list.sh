#!/usr/bin/env bash
set -e
set -u
set -o pipefail
# Remove the temp file on exit
trap 'rm -f "$TMPFILE"' EXIT

# Create a temp file for the json payload, exiting if it can't create it
TMPFILE=""
TMPFILE=$(mktemp /tmp/complex_json.XXXXXXXXXXXXXX) || exit 1

# craft a list from the options in $SHELLOPTS and save it to a variable
#     replace colons with commas
#     append a newline after each comma
#     add quotes around each word
shellopts=$(echo $SHELLOPTS \
  | tr ':' ',' \
  | sed 's/,/,\n/g' \
  | sed 's/[^,]*/"&"/')

# use a heredoc to craft a complex payload, using variables from defined earlier in the script
cat << EOF > "$TMPFILE"
{
  "shellopts": [
    $shellopts
  ]
}
EOF

# cat the payload to STDOUT
cat "$TMPFILE"