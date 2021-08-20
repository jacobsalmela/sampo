#!/usr/bin/env bash
set -e
set -u
set -o pipefail

# this is the dir to list, from which the JSON payload will be crafted
# it will create a list of dictionaries with all the information 'ls' provides
dir_to_list="/tmp"
# print a long listing, supressing the 'total: <size>' line
cmd_string="ls -ldh $dir_to_list/*"
# run the command string in a subshell and save it's output to a variable
ls_output=$($cmd_string)
# check the length of the output so we know how many lines there are
line=$(echo "$ls_output" | wc -l)
# index to detect last line in while loop
i=0

# craft the first part of the payload
echo "{"
# this will be a list of dicts, each one being a file under the keyname, which is the folder we are listing
echo "\"$dir_to_list\": {"
# for each line, craft the string into a dict and append it to an array
while read -r l
do
  i=$((i+1))
  fname=$(echo "$l" | awk '{print $9}')
  mode=$(echo "$l" | awk '{print $1}')
  inodes=$(echo "$l" | awk '{print $2}')
  owner=$(echo "$l" | awk '{print $3}')
  group=$(echo "$l" | awk '{print $4}')
  size=$(echo "$l" | awk '{print $5}')
  modified=$(echo "$l" | awk '{print $6 " " $7 " " $8}')
  # start the dict
  echo "\"$fname\": {"
  echo "\"mode\": \"$mode\","
  echo "\"inodes\": \"$inodes\","
  echo "\"owner\": \"$owner\","
  echo "\"group\": \"$group\","
  echo "\"size\": \"$size\","
  echo "\"modified\": \"$modified\""

  # if this is not the last line, append a comma
  if [[ $i -ne $line ]]; then
    echo "},"
  else
    # if this is the last line, only append a closing bracket since it's the last element
    echo "}"
  fi
done << EOF
$($cmd_string)
EOF

# close the list
echo "}"
# close the payload
echo "}"