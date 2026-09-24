#!/usr/bin/env bash
set -eE
set -u
set -o functrace
set -o pipefail
if [[ "${DEBUG:=false}" == "true" ]]; then
  set -x
fi

# die traps on ERR and runs die() with the current line number command
die() {
  local lineno="${1}"
  local msg="${2}"
  echo "**         **"
  echo "** FAILURE ** at line $lineno: $msg"
  echo "**         **"
}

# Run cleanup function in interrupt
trap cleanup SIGINT
# trap on error and print the line number and command
trap 'die ${LINENO} "$BASH_COMMAND"' ERR

readonly APP=sampo
readonly VERSION=1.0.3
readonly BATS_CORE=test/test_helper/bats-core/bin/bats

# get the user config, PORT, LOCAL_PORT, and the SAMPO_BASE are set here
#shellcheck source=docker/sampo/sampo.conf
source docker/sampo/sampo.conf

REBUILD="false"

# Get the full directory name of the script no matter where it is being called from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
LOG_FILE="$DIR/$APP.log"
K8S_YML=k8s-$APP

usage() {
  grep '^#/' "$0" | cut -c4-
}

cleanup() {
  echo "Running cleanup..."

  echo "Removing k8s deployments..."
  if ! delete_k8s; then
    echo "No stale deployments to remove"
  fi

  echo "Removing stale containers..."
  if ! remove_stale_containers; then
    echo "No stale containers to remove"
  fi

  echo "Stopping socat..."
  if ! stop_proc "socat"; then
    echo "No socat to stop"
  fi
}

run_all_tests() {
  echo "Running FULL test suite"
  # BATS doesn't always work, but it's a nice quick inidicator if things are decent while developing this.
  if ! $BATS_CORE "$DIR/test/"; then
    echo "Bats tests failed.  Please fix before continuing."
    return 0
  fi
}

run_unit_tests() {
  echo "Running UNIT test suite"
  if ! $BATS_CORE --filter-tags unit "$DIR/test/"; then
    echo "Bats tests failed.  Please fix before continuing."
    return 0
  fi
}

run_integration_tests() {
  echo "Running INTEGRATION test suite"
  if ! $BATS_CORE --filter-tags integration "$DIR/test/"; then
    echo "Bats tests failed.  Please fix before continuing."
    return 0
  fi
}

build_container() {
  local container_runtimes=("docker" "podman")
  local container_binary=""
  for container_runtime in "${container_runtimes[@]}"; do
    if command -v "${container_runtime}" 1>/dev/null; then
      container_binary="${container_runtime}"
      break
    fi
  done
  if [[ -z "${container_binary}" ]]; then
    echo "No suitable container runtime found. Checked: ${container_runtimes[*]}"
    exit 1
  fi


  if [[ "${REBUILD}" == "true" ]] || [[ "$(docker images -q "$APP":"$VERSION" 2> /dev/null)" == "" ]]; then
    echo "Rebuilding image..."
    if "${container_binary}" build -t "$APP":"$VERSION" -f ./docker/Dockerfile ./docker; then
      "${container_binary}" container prune --filter "label=app=$APP" --force
      "${container_binary}" image prune --filter "label=app=$APP" --force
      "${container_binary}" images --filter "label=app=$APP"
    fi
  else
    echo "Using existing image..."
  fi
}

stop_socat_netcat() {
  echo "Stopping socat and netcat..."
  if ! pkill socat; then
    echo "No socat to stop"
  fi
  if ! pkill nc; then
    echo "No netcat to stop"
  fi
}

remove_stale_containers() {
  echo "Removing stale containers..."
  # also check for untagged images that are hanging around
  declare -a running_containers
  IFS=" " read -r -a running_containers <<< "$(docker ps -a | awk -v i="^$APP.*" '{if($2~i){print$1}}')"
  if [[ "${#running_containers[@]}" -gt 0 ]]; then
    for container in "${running_containers[@]}"
    do
      # stop them
      docker stop "${container}"
    done
    # check again since some containers are removed when stopped
    IFS=" " read -r -a running_containers <<< "$(docker ps -a | awk -v i="^$APP.*" '{if($2~i){print$1}}')"
    # remove any remaining containers
    if [[ "${#running_containers[@]}" -gt 0 ]]; then
      for container in "${running_containers[@]}"
      do
        # rm them
        docker rm "${container}"
      done
    fi
  fi

 IFS=" " read -r -a running_containers <<< "$(docker container ls -a --filter=name=$APP --format "{{.ID}}")"
  if [[ "${#running_containers[@]}" -gt 0 ]]; then
    for container in "${running_containers[@]}"
    do
      # stop them
      docker stop "${container}"
    done
    # check again since some containers are removed when stopped
    IFS=" " read -r -a running_containers <<< "$(docker container ls -a --filter=name=$APP --format "{{.ID}}")"
    # remove any remaining containers
    if [[ "${#running_containers[@]}" -gt 0 ]]; then
      for container in "${running_containers[@]}"
      do
        # rm them
        docker rm "${container}"
      done
    fi
  fi
}


build_run_local() {
  echo "Running locally..."
  if ! command -v socat >/dev/null; then
    echo "socat is required to run this locally.  Please install it and try again."
    exit 1
  fi


  socat TCP-LISTEN:"$PORT",reuseaddr,fork,pf=ip4 \
    exec:docker/"$APP"/"$APP".sh >/dev/null &
  
  # run tests
  run_integration_tests
  # if everything was good, show a helpful message
  echo "Useful commands for developing this local deployment, run:"
  echo "    tail -f $LOG_FILE"
  echo "    curl http://localhost:${LOCAL_PORT}/"
  echo "    ./build -c (cleanup this deployment)"
}

build_run_k8s() {
  local pod=""
  local running_pod=""
  if ! command -v kubectl 1>/dev/null; then
    echo "kubectl needs to be installed"
    exit 1
  fi
  build_container

  echo "Removing existing..."
  delete_k8s
  echo "Deploying..."
  apply_k8s
  
  # Wait for the pod to come up
  echo "Waiting for pod to be ready..."
  # Until Running is found in the output of the kubectl command
  until [[ -n "${running_pod:=}" ]];
  do
    # Check the pods until they are Running
    running_pod="$(kubectl get --namespace=$APP pod -l app="$APP" --field-selector=status.phase==Running 2>/dev/null)"
    kubectl get --namespace=$APP pod -l app="$APP" --no-headers
  done
  running_pod=$(kubectl get --namespace=$APP pod -l app="$APP" --no-headers -o custom-columns=":metadata.name")
  enable_port_forwarding
  run_integration_tests
  kubectl get po -l app="$APP" -o wide
  echo "Useful commands for developing this k8s deployment, run:"
  echo "    kubectl -n sampo exec -it ${running_pod} -- bash"
  echo "    kubectl -n sampo logs ${running_pod}"
  echo "    curl http://localhost:${LOCAL_PORT}/"
  echo "    ./build -c (cleanup this deployment)"
}


stop_proc() {
  local process="${1}"
  local pid=""
  # Kill any port-forwarding processes
  if pgrep -lf "$process"; then
    pgrep -lf "$process" | awk '{print $1}' | xargs ps -fp ;
    pid=$(pgrep -lf "$process" | awk '{print $1}')
    echo "Killing listening pid $pid"
    kill "$pid"
  fi
}


list_port_forward() {
  if pgrep -lf 'kubectl port-forward'; then
    kubectl get svc -n=$APP -o json | jq '.items[] | {name:.metadata.name, p:.spec.ports[] } | select( .p.nodePort != null ) | "\(.name): localhost:\(.p.nodePort) -> \(.p.port) -> \(.p.targetPort)"'
  fi
}

create_namespace() {
  kubectl apply -f "$K8S_YML"/namespace.yml
}

delete_namespace() {
  namespace=$(kubectl get namespace -l app="$APP" --no-headers -o custom-columns=":metadata.name")
  if [[ -n "$namespace" ]]; then
    kubectl delete -f "$K8S_YML"/namespace.yml
  fi
}

create_service() {
  kubectl apply -f "$K8S_YML"/service.yml
}

delete_service() {
  service=$(kubectl get --namespace=$APP service -l app="$APP" --no-headers -o custom-columns=":metadata.name")
  if [[ -n "$service" ]]; then
    kubectl delete -f "$K8S_YML"/service.yml
  fi
}

create_deployment() {
  kubectl apply -f "$K8S_YML"/deployment.yml
}

delete_deployment() {
  deployment=$(kubectl get --namespace=$APP deployment -l app="$APP" --no-headers -o custom-columns=":metadata.name")
  if [[ -n "$deployment" ]]; then
    kubectl delete -f "$K8S_YML"/deployment.yml --grace-period=60
  fi
  
}

create_configmap() {
  local config="k8s-$APP-conf"
  local scripts="k8s-$APP-scripts"
  # create configmaps from sampo conf and scripts
  kubectl create cm --namespace="$APP" "${config}" --from-file=docker/$APP/"$APP".conf
  kubectl label cm --namespace="$APP" "${config}" app=$APP
  
  kubectl create cm --namespace="$APP" "${scripts}" --from-file=docker/$APP/scripts
  kubectl label cm --namespace="$APP" "${scripts}" app=$APP
}

delete_configmap() {
  local config="k8s-$APP-conf"
  local scripts="k8s-$APP-scripts"
  local configmaps=("$config" "$scripts")
  for cm in "${configmaps[@]}"; do
    if [[ -n "$(kubectl get configmap --namespace=$APP --no-headers -l app="$APP" 2>/dev/null)" ]]; then
      kubectl delete configmap --namespace=$APP "$cm"
    fi
  done
}

apply_k8s() {
  # Create namespace if it doesn't exist
  if ! kubectl get ns $APP --no-headers 2>/dev/null; then
    kubectl create -f "$K8S_YML"/namespace.yml
  fi

  create_configmap

  create_service

  create_deployment
}

delete_k8s() {
  delete_configmap

  delete_service

  delete_deployment

  # echo "---- NAMESPACE ----"
  # delete_namespace
 
  stop_proc "kubectl port-forward"
}

get_existing_k8s() {
  # Create name space if it doesn't exist
  echo "---- NAMESPACE ----"
  if ! kubectl get ns $APP 2>/dev/null; then
    echo "No namespace $APP found."
  else

    echo "---- CONFIGMAPS ----"
    if ! kubectl get --namespace=$APP cm -o wide -l app=$APP 2>/dev/null; then
      echo "No configmaps found for $APP."
    fi

    echo "---- SERVICE ----"
    if ! kubectl get --namespace=$APP service -l app="$APP" -o wide 2>/dev/null; then
      echo "No service found for $APP."
    fi

    echo "---- DEPLOYMENT ----"
    if ! kubectl get --namespace=$APP deployment -l app="$APP" -o wide 2>/dev/null; then
      echo "No deployment found for $APP."
    fi

    echo "---- PODS ----"
    if ! kubectl get --namespace=$APP pods -l app="$APP" -o wide; then
      echo "No pods found for $APP."
    fi 

    echo "---- PORT FORWARDING ----"
    list_port_forward
  fi
 
}

enable_port_forwarding() {
  local pod
  #shellcheck disable=SC2016
  pod=$(kubectl get --namespace=$APP pods -l app="$APP" -o=go-template --template='{{range .items}}{{$ready:=true}}{{range .status.containerStatuses}}{{if not .ready}}{{$ready = false}}{{end}}{{end}}{{if $ready}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
  if [[ -z "$pod" ]]; then
    echo "No pod found for $APP."
    return 1
  fi
  echo "Enabling port forwarding for $pod..."
  # Set up local port forwarding running in the background
  kubectl port-forward --address 0.0.0.0 --namespace "$APP" "$pod" "$LOCAL_PORT":"$PORT" >/dev/null &
  list_port_forward
}

build_run_docker() {
  remove_stale_containers
  build_container
  echo "Starting new container"
  # Run the new container mounting the examples folder for the sample scripts
  # -v "docker/sampo":/sampo:ro \
  # Mount the test fixtures at the same path as on the host, so the integration tests can request them through /file/
  docker run -d \
    --name "$APP" \
    --rm \
    -p "$LOCAL_PORT":"$PORT" \
    -v "$DIR/test/fixtures":"$DIR/test/fixtures":ro \
    "$APP":"$VERSION"
  run_integration_tests
  docker container ls -a
  docker ps -a --format="{{.Image}}    {{.Status}}     {{.Ports}}" --filter ancestor="$APP":"$VERSION"
  container=""
  container=$(docker ps -a | awk -v i="^$APP.*" '{if($2~i){print$1}}')
  echo "Useful commands for developing this container, run:"
  echo "    docker exec -it ${container} bash"
  echo "    docker logs ${container}"
  echo "    curl http://localhost:${LOCAL_PORT}/"
  echo "    ./build -c (cleanup this deployment)"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

# anything below this line with a #/ will show up in the usage line
#/ Usage: build.sh [-h] -[d|k] [-c]
#/
#/   A shell script that builds, tests, and runs the sampo software
#/
#/    -h      show this help
#/    -b      build the container
#/    -d      build and run this in docker
#/    -k      build and run this in kubernetes (Docker for Mac)
#/    -l      build and run this running in a local shell connected with socat
#/    -K      list kube deployments
#/    -p      list port forwarding rule
#/    -r      rebuild the container (must preceed other options)
#/    -c      cleanup any previous runs
#/    -t      run all tests
#/    -u      run unit tests
#/    -i      run integration tests

while getopts ":hvbdkKlpcrtui" opt; do
  case ${opt} in
    h ) usage
      ;;
    b ) REBUILD=true build_container
      ;;
    d ) build_run_docker
      ;;
    k ) build_run_k8s
      ;;
    K ) get_existing_k8s
      ;;
    l ) build_run_local
      ;;
    p ) list_port_forward
      ;;
    c ) cleanup
      ;;
    r ) REBUILD=true
      ;;
    t ) run_all_tests
      ;;
    u ) run_unit_tests
      ;;
    i ) run_integration_tests
      ;;
    * ) usage
      ;;
  esac
done
