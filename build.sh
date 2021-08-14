#!/usr/bin/env bash
#shellcheck source=./vars.bash
source ./vars.bash

# Run cleanup function in interrupt
trap cleanup SIGINT

# Get the full directory name of the script no matter where it is being called from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# anything below this line with a #/ will show up in the usage line
#/ Usage: build.sh [-h] -[d|k] [-c]
#/
#/   A shell script that builds the sampo software
#/
#/    -h      show this help
#/    -d      build and run this in docker
#/    -k      build and run this in kubernetes (Docker for Mac)
#/    -c      cleanup any previous runs

usage() {
  grep '^#/' "$0" | cut -c4-
}

cleanup() {
  echo "Running cleanup..."
  #shellcheck disable=SC2009
  for p in $(ps aux | grep port-forward | grep -v grep | awk '{print $2}'); do kill -9 "$p"; done 2>/dev/null
  kubectl delete -f "$APP"/ 2>/dev/null
  docker rm "$(docker stop "$(docker ps -a | awk -v i="^$APP.*" '{if($2~i){print$1}}')" 2>/dev/null)" 2>/dev/null
}

docker_build() {
  if ! eval command -v docker 1>/dev/null; then
    echo "docker needs to be installed"
    exit 1
  fi
  # cd into the build directory
  pushd docker/"$APP" >/dev/null || exit 1
    # Build the image
    docker build -t "$APP":"$VERSION" .
  # exit directory
  popd >/dev/null || exit 1
}

run_unit_tests() {
  echo -e "\nRunning test suite"
  # BATS doesn't always work, but it's a nice quick inidicator if things are decent while developing this.
  bats "$DIR/test/$APP.bats"
}

# test_title() {
#   local test
#   local test_length
#   local width
#   local fill
#   # First argument passed is just a strings
#   test="$1"
#   # Get character length of string
#   test_length="$(echo -n "$1" | wc -m | sed 's/^[[:space:]]*//g')"
#   # Get width of terminal
#   width="$(tput cols)"
#   # Subtract the length of the string from the width of the terminal
#   stuff=$( expr ${width} - ${test_length} )
#   # Variable to hold a character to fill the line
#   fill="$(printf '%*s\n' ${stuff} '' | tr ' ' \#)"
#   echo "$test$fill"
# }

build_k8s() {
  if ! eval command -v kubectl 1>/dev/null; then
    echo "kubectl needs to be installed"
    exit 1
  fi
  docker_build
  # Kill any port-forwarding processes
  for p in $(ps aux | grep port-forward | grep -v grep | awk '{print $2}'); do kill -9 $p; done
  # Delete the old deployment
  kubectl delete -f "$APP"/ >/dev/null
  # Create the deployment
  kubectl create -f "$APP"/
  # Wait for the pod to come up
  echo "Waiting for pod to be ready..."
  # Until Running is found in the output of the kubectl command
  until [[ "$RUNNING_POD" == *Running* ]]
  do
    # Check the pods until they are Running
    RUNNING_POD="$(kubectl get pod -l app="$APP" --field-selector=status.phase==Running)"
    # RUNNING_POD="$(kubectl get pods -o custom-columns=NAMESPACE:metadata.namespace,POD:metadata.name,PodIP:status.podIP,READY-true:status.containerStatuses[*].ready | grep true)"
    echo "Terminiating.."
  done
  # Get the pod name in a variable
  # POD=$(kubectl get pod -l app=$APP --field-selector=status.phase==Running -o jsonpath="{.items[0].metadata.name}")
  #shellcheck disable=SC2016
  POD=$(kubectl get pods -l app="$APP" -o=go-template --template='{{range .items}}{{$ready:=true}}{{range .status.containerStatuses}}{{if not .ready}}{{$ready = false}}{{end}}{{end}}{{if $ready}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
  # DEPLOYMENT=$(kubectl get deployment -l app=$APP -o=go-template --template='{{range .items}}{{$ready:=true}}{{range .status.containerStatuses}}{{if not .ready}}{{$ready = false}}{{end}}{{end}}{{if $ready}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
  # echo "Enabling port forwarding for $DEPLOYMENT..."
  echo "Enabling port forwarding for $POD..."
  # Set up local port forwarding in a screen for that pod
  # screen -d -S $APP -m kubectl port-forward $POD $PORT:$PORT
  kubectl port-forward --address 0.0.0.0 "$POD" "$PORT":"$PORT" >/dev/null &
  # kubectl port-forward --address 0.0.0.0 deployment/"$DEPLOYMENT" :$PORT >/dev/null &
  # ps aux | grep port-forward | grep -v grep
  sleep 3
  run_unit_tests
}

build_docker() {
  docker_build
  # SCREEN_REGEX="[0-9]*\.$APP"
  # Cleanup from last run
  # Remove any screen sessions
  # for session in $(screen -ls | grep -o \'$SCREEN_REGEX\'); do screen -S "${session}" -X quit; done >/dev/null
  # check for running containers of sampo
  # running_containers=$(docker ps -a | awk -v i="^$APP.*" '{if($2~i){print$1}}')
  running_containers=$(docker ps -a -q --filter ancestor="$APP":"$VERSION" --format="{{.ID}}")
  if [[ -n "$running_containers" ]]; then
    # Stop and remove all older running containers
    # Stop all by a specific version
    # docker rm "$(docker stop "$(docker ps -a -q --filter ancestor=$APP:$VERSION --format="{{.ID}}")")"
    # Stop all by image name only
    for c in $running_containers
    do
      echo "Stopping and removing old container: $c"
      docker rm "$(docker stop "$c" 2>/dev/null)" 2>/dev/null
    done
    # Run it in a docker container by default, mounting the examples directory, which contains all the scripts
  fi
  docker run -d \
    -v "$(pwd)"/examples:/"$APP" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -p "$LOCAL_PORT":"$PORT" \
    "$APP":"$VERSION"
  sleep 3
  run_unit_tests
  echo -e "To debug this container, run:\n"
  echo "    docker exec -it $(docker ps -a | awk -v i="^sampo.*" '{if($2~i){print$1}}') bash"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while getopts ":hdkc" opt; do
  case ${opt} in
    h ) usage
      ;;
    d ) build_docker
      ;;
    k ) build_k8s
      ;;
    c ) cleanup
      ;;
    * ) usage
      ;;
  esac
done
