#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# A library of helper functions and constants for the local config.

# Use the config file specified in $KUBE_CONFIG_FILE, or default to
# config-default.sh.
KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${KUBE_ROOT}/cluster/vsphere/config-common.sh"
source "${KUBE_ROOT}/cluster/vsphere/${KUBE_CONFIG_FILE-"config-default.sh"}"

# Detect the IP for the master
#
# Assumed vars:
#   MASTER_NAME
# Vars set:
#   KUBE_MASTER
#   KUBE_MASTER_IP
function detect-master {
  KUBE_MASTER=${MASTER_NAME}
  if [[ -z "${KUBE_MASTER_IP-}" ]]; then
    KUBE_MASTER_IP=$(govc vm.ip ${MASTER_NAME})
  fi
  if [[ -z "${KUBE_MASTER_IP-}" ]]; then
    echo "Could not detect Kubernetes master node. Make sure you've launched a cluster with 'kube-up.sh'" >&2
    exit 1
  fi
  echo "Using master: $KUBE_MASTER (external IP: $KUBE_MASTER_IP)"
}

# Detect the information about the minions
#
# Assumed vars:
#   MINION_NAMES
# Vars set:
#   KUBE_MINION_IP_ADDRESS (array)
function detect-minions {
  KUBE_MINION_IP_ADDRESSES=()
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    local minion_ip=$(govc vm.ip ${MINION_NAMES[$i]})
    if [[ -z "${minion_ip-}" ]] ; then
      echo "Did not find ${MINION_NAMES[$i]}" >&2
    else
      echo "Found ${MINION_NAMES[$i]} at ${minion_ip}"
      KUBE_MINION_IP_ADDRESSES+=("${minion_ip}")
    fi
  done
  if [[ -z "${KUBE_MINION_IP_ADDRESSES-}" ]]; then
    echo "Could not detect Kubernetes minion nodes. Make sure you've launched a cluster with 'kube-up.sh'" >&2
    exit 1
  fi
}

function trap-add {
  local handler="$1"
  local signal="${2-EXIT}"
  local cur

  cur="$(eval "sh -c 'echo \$3' -- $(trap -p ${signal})")"
  if [[ -n "${cur}" ]]; then
    handler="${cur}; ${handler}"
  fi

  trap "${handler}" ${signal}
}

function verify-prereqs {
  which "govc" >/dev/null || {
    echo "Can't find govc in PATH, please install and retry."
    echo ""
    echo "    go install github.com/vmware/govmomi/govc"
    echo ""
    exit 1
  }
}

function verify-ssh-prereqs {
  local rc

  rc=0
  ssh-add -L 1> /dev/null 2> /dev/null || rc="$?"
  # "Could not open a connection to your authentication agent."
  if [[ "${rc}" -eq 2 ]]; then
    eval "$(ssh-agent)" > /dev/null
    trap-add "kill ${SSH_AGENT_PID}" EXIT
  fi

  rc=0
  ssh-add -L 1> /dev/null 2> /dev/null || rc="$?"
  # "The agent has no identities."
  if [[ "${rc}" -eq 1 ]]; then
    # Try adding one of the default identities, with or without passphrase.
    ssh-add || true
  fi

  # Expect at least one identity to be available.
  if ! ssh-add -L 1> /dev/null 2> /dev/null; then
    echo "Could not find or add an SSH identity."
    echo "Please start ssh-agent, add your identity, and retry."
    exit 1
  fi
}

# Create a temp dir that'll be deleted at the end of this bash session.
#
# Vars set:
#   KUBE_TEMP
function ensure-temp-dir {
  if [[ -z ${KUBE_TEMP-} ]]; then
    KUBE_TEMP=$(mktemp -d -t kubernetes.XXXXXX)
    trap-add 'rm -rf "${KUBE_TEMP}"' EXIT
  fi
}

# Verify and find the various tar files that we are going to use on the server.
#
# Vars set:
#   SERVER_BINARY_TAR
#   SALT_TAR
function find-release-tars {
  SERVER_BINARY_TAR="${KUBE_ROOT}/server/kubernetes-server-linux-amd64.tar.gz"
  if [[ ! -f "$SERVER_BINARY_TAR" ]]; then
    SERVER_BINARY_TAR="${KUBE_ROOT}/_output/release-tars/kubernetes-server-linux-amd64.tar.gz"
  fi
  if [[ ! -f "$SERVER_BINARY_TAR" ]]; then
    echo "!!! Cannot find kubernetes-server-linux-amd64.tar.gz"
    exit 1
  fi

  SALT_TAR="${KUBE_ROOT}/server/kubernetes-salt.tar.gz"
  if [[ ! -f "$SALT_TAR" ]]; then
    SALT_TAR="${KUBE_ROOT}/_output/release-tars/kubernetes-salt.tar.gz"
  fi
  if [[ ! -f "$SALT_TAR" ]]; then
    echo "!!! Cannot find kubernetes-salt.tar.gz"
    exit 1
  fi
}

# Take the local tar files and upload them to the master.
#
# Assumed vars:
#   MASTER_NAME
#   SERVER_BINARY_TAR
#   SALT_TAR
function upload-server-tars {
  local vm_ip

  vm_ip=$(govc vm.ip "${MASTER_NAME}")
  kube-ssh ${vm_ip} "mkdir -p /home/kube/cache/kubernetes-install"

  local tar
  for tar in "${SERVER_BINARY_TAR}" "${SALT_TAR}"; do
    kube-scp ${vm_ip} "${tar}" "/home/kube/cache/kubernetes-install/${tar##*/}"
  done
}

# Ensure that we have a password created for validating to the master. Will
# read from $HOME/.kubernetes_auth if available.
#
# Vars set:
#   KUBE_USER
#   KUBE_PASSWORD
function get-password {
  local file="$HOME/.kubernetes_auth"
  if [[ -r "$file" ]]; then
    KUBE_USER=$(cat "$file" | python -c 'import json,sys;print json.load(sys.stdin)["User"]')
    KUBE_PASSWORD=$(cat "$file" | python -c 'import json,sys;print json.load(sys.stdin)["Password"]')
    return
  fi
  KUBE_USER=admin
  KUBE_PASSWORD=$(python -c 'import string,random; print "".join(random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16))')

  # Store password for reuse.
  cat << EOF > "$file"
{
  "User": "$KUBE_USER",
  "Password": "$KUBE_PASSWORD"
}
EOF
  chmod 0600 "$file"
}

# Run command over ssh
function kube-ssh {
  local host="$1"
  shift
  ssh ${SSH_OPTS-} "kube@${host}" "$@" 2> /dev/null
}

# Copy file over ssh
function kube-scp {
  local host="$1"
  local src="$2"
  local dst="$3"
  scp ${SSH_OPTS-} "${src}" "kube@${host}:${dst}"
}

# Instantiate a generic kubernetes virtual machine (master or minion)
#
# Usage:
#   kube-up-vm VM_NAME [options to pass to govc vm.create]
#
# Example:
#   kube-up-vm "vm-name" -c 2 -m 4096
#
# Assumed vars:
#   DISK
#   GUEST_ID
function kube-up-vm {
  local vm_name="$1"
  shift

  govc vm.create \
    -debug \
    -disk="${DISK}" \
    -g="${GUEST_ID}" \
    -link=true \
    "$@" \
    "${vm_name}"

  # Retrieve IP first, to confirm the guest operations agent is running.
  govc vm.ip "${vm_name}" > /dev/null

  govc guest.mkdir \
    -vm="${vm_name}" \
    -p \
    /home/kube/.ssh

  ssh-add -L > "${KUBE_TEMP}/${vm_name}-authorized_keys"

  govc guest.upload \
    -vm="${vm_name}" \
    -f \
    "${KUBE_TEMP}/${vm_name}-authorized_keys" \
    /home/kube/.ssh/authorized_keys
}

# Kick off a local script on a kubernetes virtual machine (master or minion)
#
# Usage:
#   kube-run VM_NAME LOCAL_FILE
function kube-run {
  local vm_name="$1"
  local file="$2"
  local dst="/tmp/$(basename "${file}")"
  govc guest.upload -vm="${vm_name}" -f -perm=0755 "${file}" "${dst}"

  local vm_ip
  vm_ip=$(govc vm.ip "${vm_name}")
  kube-ssh ${vm_ip} "nohup sudo ${dst} < /dev/null 1> ${dst}.out 2> ${dst}.err &"
}

# Instantiate a kubernetes cluster
#
# Assumed vars:
#   KUBE_ROOT
#   <Various vars set in config file>
function kube-up {
  verify-ssh-prereqs
  find-release-tars

  ensure-temp-dir

  get-password
  python "${KUBE_ROOT}/third_party/htpasswd/htpasswd.py" \
    -b -c "${KUBE_TEMP}/htpasswd" "$KUBE_USER" "$KUBE_PASSWORD"
  local htpasswd
  htpasswd=$(cat "${KUBE_TEMP}/htpasswd")

  echo "Starting master VM (this can take a minute)..."

  (
    echo "#! /bin/bash"
    echo "readonly MY_NAME=${MASTER_NAME}"
    grep -v "^#" "${KUBE_ROOT}/cluster/vsphere/templates/hostname.sh"
    echo "cd /home/kube/cache/kubernetes-install"
    echo "readonly MASTER_NAME='${MASTER_NAME}'"
    echo "readonly NODE_INSTANCE_PREFIX='${INSTANCE_PREFIX}-minion'"
    echo "readonly PORTAL_NET='${PORTAL_NET}'"
    echo "readonly SERVER_BINARY_TAR='${SERVER_BINARY_TAR##*/}'"
    echo "readonly SALT_TAR='${SALT_TAR##*/}'"
    echo "readonly MASTER_HTPASSWD='${htpasswd}'"
    grep -v "^#" "${KUBE_ROOT}/cluster/vsphere/templates/create-dynamic-salt-files.sh"
    grep -v "^#" "${KUBE_ROOT}/cluster/vsphere/templates/install-release.sh"
    grep -v "^#" "${KUBE_ROOT}/cluster/vsphere/templates/salt-master.sh"
  ) > "${KUBE_TEMP}/master-start.sh"

  kube-up-vm ${MASTER_NAME} -c ${MASTER_CPU-1} -m ${MASTER_MEMORY_MB-1024}
  upload-server-tars
  kube-run ${MASTER_NAME} "${KUBE_TEMP}/master-start.sh"

  # Print master IP, so user can log in for debugging.
  detect-master
  echo

  echo "Starting minion VMs (this can take a minute)..."

  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    (
      echo "#! /bin/bash"
      echo "readonly MY_NAME=${MINION_NAMES[$i]}"
      grep -v "^#" "${KUBE_ROOT}/cluster/vsphere/templates/hostname.sh"
      echo "KUBE_MASTER=${KUBE_MASTER}"
      echo "KUBE_MASTER_IP=${KUBE_MASTER_IP}"
      echo "MINION_IP_RANGE=${MINION_IP_RANGES[$i]}"
      grep -v "^#" "${KUBE_ROOT}/cluster/vsphere/templates/salt-minion.sh"
    ) > "${KUBE_TEMP}/minion-start-${i}.sh"

    (
      kube-up-vm "${MINION_NAMES[$i]}" -c ${MINION_CPU-1} -m ${MINION_MEMORY_MB-1024}
      kube-run "${MINION_NAMES[$i]}" "${KUBE_TEMP}/minion-start-${i}.sh"
    ) &
  done

  local fail=0
  local job
  for job in $(jobs -p); do
      wait "${job}" || fail=$((fail + 1))
  done
  if (( $fail != 0 )); then
    echo "${fail} commands failed.  Exiting." >&2
    exit 2
  fi

  # Print minion IPs, so user can log in for debugging.
  detect-minions
  echo

  echo "Waiting for master and minion initialization."
  echo
  echo "  This will continually check to see if the API for kubernetes is reachable."
  echo "  This might loop forever if there was some uncaught error during start up."
  echo

  printf "Waiting for ${KUBE_MASTER} to become available..."
  until curl --insecure --user "${KUBE_USER}:${KUBE_PASSWORD}" --max-time 5 \
          --fail --output /dev/null --silent "https://${KUBE_MASTER_IP}/api/v1beta1/pods"; do
      printf "."
      sleep 2
  done
  printf " OK\n"

  local i
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    printf "Waiting for ${MINION_NAMES[$i]} to become available..."
    until curl --max-time 5 \
            --fail --output /dev/null --silent "http://${KUBE_MINION_IP_ADDRESSES[$i]}:10250/healthz"; do
        printf "."
        sleep 2
    done
    printf " OK\n"
  done

  echo
  echo "Sanity checking cluster..."

  sleep 5

  # Basic sanity checking
  local i
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
      # Make sure docker is installed
      kube-ssh "${KUBE_MINION_IP_ADDRESSES[$i]}" which docker > /dev/null || {
        echo "Docker failed to install on ${MINION_NAMES[$i]}. Your cluster is unlikely" >&2
        echo "to work correctly. Please run ./cluster/kube-down.sh and re-create the" >&2
        echo "cluster. (sorry!)" >&2
        exit 1
      }
  done

  echo
  echo "Kubernetes cluster is running. The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kubernetes_auth."
  echo

  local kube_cert=".kubecfg.crt"
  local kube_key=".kubecfg.key"
  local ca_cert=".kubernetes.ca.crt"

  (
    umask 077

    kube-ssh "${KUBE_MASTER_IP}" sudo cat /usr/share/nginx/kubecfg.crt >"${HOME}/${kube_cert}" 2>/dev/null
    kube-ssh "${KUBE_MASTER_IP}" sudo cat /usr/share/nginx/kubecfg.key >"${HOME}/${kube_key}" 2>/dev/null
    kube-ssh "${KUBE_MASTER_IP}" sudo cat /usr/share/nginx/ca.crt >"${HOME}/${ca_cert}" 2>/dev/null

    cat << EOF > ~/.kubernetes_auth
    {
      "User": "$KUBE_USER",
      "Password": "$KUBE_PASSWORD",
      "CAFile": "$HOME/$ca_cert",
      "CertFile": "$HOME/$kube_cert",
      "KeyFile": "$HOME/$kube_key"
    }
EOF

    chmod 0600 ~/.kubernetes_auth "${HOME}/${kube_cert}" \
      "${HOME}/${kube_key}" "${HOME}/${ca_cert}"
  )
}

# Delete a kubernetes cluster
function kube-down {
  govc vm.destroy ${MASTER_NAME} &

  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    govc vm.destroy ${MINION_NAMES[i]} &
  done

  wait
}

# Update a kubernetes cluster with latest source
function kube-push {
  verify-ssh-prereqs
  find-release-tars

  detect-master
  upload-server-tars

  (
    echo "#! /bin/bash"
    echo "cd /home/kube/cache/kubernetes-install"
    echo "readonly SERVER_BINARY_TAR='${SERVER_BINARY_TAR##*/}'"
    echo "readonly SALT_TAR='${SALT_TAR##*/}'"
    grep -v "^#" "${KUBE_ROOT}/cluster/vsphere/templates/install-release.sh"
    echo "echo Executing configuration"
    echo "sudo salt '*' mine.update"
    echo "sudo salt --force-color '*' state.highstate"
  ) | kube-ssh "${KUBE_MASTER_IP}"

  get-password

  echo
  echo "Kubernetes cluster is running.  The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kubernetes_auth."
  echo
}

# Execute prior to running tests to build a release if required for env
function test-build-release {
	echo "TODO"
}

# Execute prior to running tests to initialize required structure
function test-setup {
	echo "TODO"
}

# Execute after running tests to perform any required clean-up
function test-teardown {
	echo "TODO"
}

function setup-monitoring {
    echo "TODO"
}
