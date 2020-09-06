#!/usr/bin/env bash
# Vars
APP=sampo
VERSION=1.0
PORT=1042
# Get the full directory name of the script no matter where it is being called from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

test_title() {
  local test
  local test_length
  local width
  local fill
  # First argument passed is just a strings
  test="$1"
  # Get character length of string
  test_length="$(echo -n "$1" | wc -m | sed 's/^[[:space:]]*//g')"
  # Get width of terminal
  width="$(tput cols)"
  # Subtract the length of the string from the width of the terminal
  stuff=$( expr ${width} - ${test_length} )
  # Variable to hold a character to fill the line
  fill="$(printf '%*s\n' ${stuff} '' | tr ' ' \#)"
  echo "$test$fill"
}

# SCREEN_REGEX="[0-9]*\.$APP"
# Cleanup from last run
# Remove any screen sessions
# for session in $(screen -ls | grep -o \'$SCREEN_REGEX\'); do screen -S "${session}" -X quit; done >/dev/null
# Kill any port-forwarding processes
for p in $(ps aux | grep port-forward | grep -v grep | awk '{print $2}'); do kill -9 $p; done
# Delete the old deployment
kubectl delete -f $APP/ >/dev/null
# cd into the build directory
pushd docker/$APP >/dev/null || exit
# Build the image
docker build -t $APP:$VERSION .
# exit directory
popd >/dev/null || exit
# Create the deployment
kubectl create -f $APP/
# Wait for the pod to come up
echo "Waiting for pod to be ready..."
# Until Running is found in the output of the kubectl command
until [[ "$RUNNING_POD" == *Running* ]]
do
  # Check the pods until they are Running
  RUNNING_POD="$(kubectl get pod -l app=$APP --field-selector=status.phase==Running)"
  # RUNNING_POD="$(kubectl get pods -o custom-columns=NAMESPACE:metadata.namespace,POD:metadata.name,PodIP:status.podIP,READY-true:status.containerStatuses[*].ready | grep true)"
  echo "Terminiating.."
done
# Get the pod name in a variable
# POD=$(kubectl get pod -l app=$APP --field-selector=status.phase==Running -o jsonpath="{.items[0].metadata.name}")
POD=$(kubectl get pods -l app=$APP -o=go-template --template='{{range .items}}{{$ready:=true}}{{range .status.containerStatuses}}{{if not .ready}}{{$ready = false}}{{end}}{{end}}{{if $ready}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
# DEPLOYMENT=$(kubectl get deployment -l app=$APP -o=go-template --template='{{range .items}}{{$ready:=true}}{{range .status.containerStatuses}}{{if not .ready}}{{$ready = false}}{{end}}{{end}}{{if $ready}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
# echo "Enabling port forwarding for $DEPLOYMENT..."
echo "Enabling port forwarding for $POD..."
# Set up local port forwarding in a screen for that pod
# screen -d -S $APP -m kubectl port-forward $POD $PORT:$PORT
kubectl port-forward --address 0.0.0.0 "$POD" $PORT:$PORT >/dev/null &
# kubectl port-forward --address 0.0.0.0 deployment/"$DEPLOYMENT" :$PORT >/dev/null &
# ps aux | grep port-forward | grep -v grep

echo "Running unit tests..."
# BATS doesn't always work, but it's a nice quick inidicator if things are decent while developing this.
sleep 3
# Unit Tests
# test_title "[TEST]: Verify 'echo' endpoint returns <value>"
bats --tap "$DIR/test/$APP.bats"

# while true; do { echo -e 'HTTP/1.1 200 OK\r\n'; bash ./sampo.sh; } | nc -l 1500; done
