# shellcheck shell=bash disable=SC1091,SC2154 # sourced by sampo.sh, which sets DIR
# DELETE /topics/NAME deletes topic NAME
source "$DIR"/pubsub.sh
topic_delete "$1"
