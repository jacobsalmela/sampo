# shellcheck shell=bash disable=SC1091,SC2154 # sourced by sampo.sh, which sets DIR
# POST /topics/NAME publishes the request body to topic NAME
source "$DIR"/pubsub.sh
topic_publish "$1"
