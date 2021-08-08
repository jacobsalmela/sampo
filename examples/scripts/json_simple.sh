#!/usr/bin/env bash
printf '{
    "OS":"%s",
    "bash_version":"%s"
}\n' \
"$OSTYPE" \
"$BASH_VERSION"
