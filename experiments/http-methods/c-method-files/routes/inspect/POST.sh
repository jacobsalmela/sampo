# shellcheck shell=bash disable=SC1091,SC2154 # sourced by sampo.sh, which sets DIR
# POST /inspect: external scripts get the method in $REQUEST_METHOD and the body on STDIN
run_external_script "$DIR"/scripts/inspect.sh /inspect "$@"
