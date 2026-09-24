# shellcheck shell=bash disable=SC1091,SC2154 # sourced by sampo.sh, which sets DIR
# PUT /topics/NAME creates topic NAME, or updates its description
source "$DIR"/pubsub.sh
topic_create "$1"
