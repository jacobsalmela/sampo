# shellcheck shell=bash disable=SC1091,SC2154 # sourced by sampo.sh, which sets DIR
# GET /topics/NAME subscribes to topic NAME
source "$DIR"/pubsub.sh
topic_subscribe "$1"
