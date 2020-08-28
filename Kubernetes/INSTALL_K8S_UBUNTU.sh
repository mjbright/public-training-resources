#!/bin/bash

# Auto installer for Kubernetes
# NOTE:
# - to be run from master
# - pre-req: entries in /etc/hosts: master, worker1
# - pre-req: entries in /etc/hosts: master1, master2, ..., worker1, worker2, ...
# - local sudo access (w/o password)
# - ssh access to remote system as current user 
# - ssh access to remote system as current user and sudo access
# - ssh access to remote system as current user and ssh back to master(1)
# - swap is off
# - ?? ssh access to remote system as root ??
# - ?? ssh access to local system as current user ??
# - ?? ssh access to local system as root ??
# - unique MAC addresses

K8S_RELEASE="1.18.8-00"
K8S_RELEASE="LATEST"

CRI="docker" # ONLY docker for now ... to do cri-o AND improve logic to test if docker/cri-o already installed

NUM_ETCD_NODES=0 # On masters
NUM_MASTERS=1
NUM_WORKERS=1

POD_NETWORK_CIDR='192.168.0.0/16'
SVC_NETWORK_CIDR='10.96.0.0/12'
EXTRA_SANS=''
EXTRA_SANS='127.0.0.1'

KUBEADM_LOG=~/kubeadm_init.log
KUBEADM_JOIN_SH=/tmp/kubeadm_join.sh

## Functions: -------------------------------------------------------------------------

die() {
    echo "$0: die - $*" >&2
    exit 1
}


#    https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
INSTALL_PACKAGES() {

    local DOCKER_INSTALL=0
    local DPKGS=""
    #dpkg -l | -q apt-transport-https curl
    dpkg -l | grep -q apt-transport-https || DPKGS+=" apt-transport-https"
    dpkg -l | grep -q curl                || DPKGS+=" curl"
    dpkg -l | grep docker.io              || { DOCKER_INSTALL=1; DPKGS+=" docker.io"; }
    sudo apt-get update
    [ ! -z "$DPKGS" ] && {
        echo "---- Installing packages $DPKGS -------------------------"
        sudo apt-get install -y $DPKGS
        curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    }

    [ $DOCKER_INSTALL -ne 0 ] && grep ^docker: /etc/group | grep -q :$USER ||
        sudo usermod -a $USER -G docker

    local CREATE_K8S_REPO=0
    if [ -f /etc/apt/sources.list.d/kubernetes.list ];then
        grep -qE "deb.*https://apt.kubernetes.io/.*kubernetes-xenial.*main" /etc/apt/sources.list.d/kubernetes.list ||
        CREATE_K8S_REPO=1
    else
        CREATE_K8S_REPO=1
    fi
    [ $CREATE_K8S_REPO -ne 0 ] && {
        echo "---- Creating /etc/apt/sources.list.d/kubernetes.list ..."

        cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
        echo "---- Updating package list -------------------------- ..."
        sudo apt-get update
}

    ps -fade | grep -v " grep " | grep " kube" &&
        die "Not installing Kubernetes, as kubernetes might already be running"

    if [ "$K8S_RELEASE" = "LATEST" ]; then
        echo "---- Installing latest kubelet kubeadm kubectl ..."
        sudo apt-get install -y --allow-downgrades --allow-change-held-packages \
                 kubelet kubeadm kubectl
        sudo apt-mark hold kubelet kubeadm kubectl
    else
        echo "---- Installing $K8S_RELEASE kubelet kubeadm kubectl ..."
        sudo apt-get install -y --allow-downgrades --allow-change-held-packages \
                 kubelet=$K8S_RELEASE kubeadm=$K8S_RELEASE kubectl=$K8S_RELEASE 
        sudo apt-mark hold kubelet kubeadm kubectl
    fi

    echo
    echo "---- kubectl client version:"
    kubectl version --client -o yaml
    echo "---- kubelet version:"
    kubelet --version
    echo "---- kubeadm version:"
    kubeadm version -o yaml
}

KUBEADM_INIT_CLI() {
    local KUBEADM_OPTS=""
    [ ! -z "$SVC_NETWORK_CIDR" ] && KUBEADM_OPTS+=" --pod-network-cidr $POD_NETWORK_CIDR"
    [ ! -z "$POD_NETWORK_CIDR" ] && KUBEADM_OPTS+=" --service-cidr $SVC_NETWORK_CIDR"
    [ ! -z "$EXTRA_SANS"       ] && KUBEADM_OPTS+=" --apiserver-cert-extra-sans $EXTRA_SANS"

    local NODE_NAME="master"
    [ $NUM_MASTERS -ne 1 ] && NODE_NAME="master1"
    KUBEADM_OPTS+=" --node-name $NODE_NAME"

    echo; echo "---- sudo kubeadm init $KUBEADM_OPTS"
    sudo kubeadm init $KUBEADM_OPTS |& tee $KUBEADM_LOG
    echo "Output written to $KUBEADM_LOG"

    grep -A 2 "kubeadm join" kubeadm_init.log | tail -2 > $KUBEADM_JOIN_SH
    grep -i control $KUBEADM_JOIN_SH && echo "WARNING: looks to be more than one 'kubeadm join' command in $KUBEADM_JOIN_SH"
    chmod +x $KUBEADM_JOIN_SH

    COPY_KUBECONFIG
}

COPY_KUBECONFIG() {
    mkdir -p $HOME/.kube
    sudo cp -i  /etc/kubernetes/admin.conf $HOME/.kube/config
    #sudo chown $(id -u):$(id -g) $HOME/.kube/config
    sudo chown -R $(id -u):$(id -g) $HOME/.kube/
}

KUBEADM_JOIN_CLI() {
    local VERBOSE=1

    [ $VERBOSE -ne 0 ] && echo "Joining worker{1..$NUM_WORKERS}"
    for NODE_NUM in $(seq $NUM_WORKERS); do
        local NODE_NAME=worker${NODE_NUM}
        scp -p $KUBEADM_JOIN_SH ${NODE_NAME}:$KUBEADM_JOIN_SH
        ssh -qt $NODE_NAME "sudo bash -x $KUBEADM_JOIN_SH"
    done

    [ $VERBOSE -ne 0 ] && echo "Waiting for worker{1..$NUM_WORKERS} to be joined"
    for NODE_NUM in $(seq $NUM_WORKERS); do
        local NODE_NAME=worker${NODE_NUM}
        while ! kubectl get no --no-headers | grep " $NODE_NAME "; do echo "Waiting for $NODE_NAME node to appear"; sleep 1; done
    done
}

INSTALL_CNI_CALICO() {
    echo; echo "-- Downloading calico manifests ------------------------"
    wget -q -O calico-tigera-operator.yaml  https://docs.projectcalico.org/manifests/tigera-operator.yaml
    wget -q -O calico-custom-resources.yaml https://docs.projectcalico.org/manifests/custom-resources.yaml

    echo "Checking POD_NETWORK_CIDR is set to $POD_NETWORK_CIDR in calico-custom-resources.yaml"
    sed -e 's/#.*//' < calico-custom-resources.yaml | grep $POD_NETWORK_CIDR || die "Failed"

    echo; echo "-- Creating calico operator ------------------------"
    kubectl create -f calico-tigera-operator.yaml
    echo; echo "-- Creating calico custom resources ----------------"
    kubectl create -f calico-custom-resources.yaml

    # Wait for up to 2 minutes
    WAIT_MASTER_ALL_PODS_RUNNING 6 20 || {
        echo; echo "Calico setup is slow ... retrying"
        echo "-- Killing coredns Pods ------------------------------"
	kubectl -n kube-system delete pod $(kubectl -n kube-system get pods | awk '/^coredns/ { print $1; }')
        echo "-- Reapplying calico custom resources ----------------"
        kubectl apply -f calico-custom-resources.yaml
    }

    WAIT_MASTER_ALL_PODS_RUNNING 6 20 || die "Calico setup  creation failed"
}

WAIT_MASTER_PODS_RUNNING() {
    local SLEEP="$1";     shift
    local MAX_LOOPS="$1"; shift

    [ -z "SLEEP" ]     && SLEEP=2
    [ -z "MAX_LOOPS" ] && MAX_LOOPS=100

    local LOOP=0
    while kubectl get pods -n kube-system --no-headers | grep -v coredns | grep -v " Running "; do
        let LOOP=LOOP+1
	[ $LOOP -gt $MAX_LOOPS ] && { echo "Max loops exceeded"; return 1; }

        echo "Waiting for all Pods (except coredns) to be 'Running' ..."
        sleep $SLEEP;
    done

    return 0
}

WAIT_MASTER_ALL_PODS_RUNNING() {
    local SLEEP="$1";     shift
    local MAX_LOOPS="$1"; shift

    [ -z "SLEEP" ] && SLEEP=2
    [ -z "MAX_LOOPS" ] && MAX_LOOPS=100

    local LOOP=0
    while kubectl get pods -n kube-system --no-headers | grep -v " Running "; do
        let LOOP=LOOP+1
	[ $LOOP -gt $MAX_LOOPS ] && { echo "Max loops exceeded"; return 1; }

        echo "Waiting for all Pods to be 'Running' ..."
        sleep $SLEEP;
    done

    return 0
}

# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
CREATE_CLUSTER() {
    KUBEADM_INIT_CONFIG_YAML
    KUBEADM_INIT_CLI

    # Wait before joining:
    while ! kubectl get no --no-headers | grep " master "; do echo "Waiting for master node to appear"; sleep 1; done
    WAIT_MASTER_PODS_RUNNING 2 100 || die "Master creation failed"

    KUBEADM_JOIN_CLI
}

# CHECK_PREREQ:
# Returns 0 if OK
# Returns 1 if NOT OK
#
# based on part of thses checks:
#    https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
CHECK_PREREQS() {
    local VERBOSE=1
    ERRORS=""
    local NODE_NUM

    cp /dev/null /tmp/iplink.addr
    cp /dev/null /tmp/iplink.addr.nodes

    ## -- CHECKS on master node(s): -------------------------------------------------------------
    if [ $NUM_MASTERS -eq 1 ]; then
        MAC_ADDR=$(ip link | grep -E "eth|ens" -m 1 -A +1 | tail -1 | awk '{ print $2; }')
        echo $MAC_ADDR >> /tmp/iplink.addr
        echo "master $MAC_ADDR" >> /tmp/iplink.addr.nodes

        [ $VERBOSE -ne 0 ] && echo "Checking no swap is enabled on master"
        mount | grep -i swap && ERRORS+="Swap is enabled on master - disable using 'sudo swapoff -a'"

        [ $VERBOSE -ne 0 ] && echo "Checking presence of master in /etc/hosts"
        grep -q "\bmaster\b" /etc/hosts || ERRORS+="No entry for master in /etc/hosts"
    else
        [ $VERBOSE -ne 0 ] && echo "Checking no swap is enabled on master{1..$NUM_MASTERS}"
        for NODE_NUM in $(seq $NUM_MASTERS); do
            local NODE_NAME=master${NODE_NUM}
            mount | grep -i swap && ERRORS+="Swap is enabled on ${NODE_NAME} - disable using 'sudo swapoff -a'"
        done

        [ $VERBOSE -ne 0 ] && echo "Checking presence of master{1..$NUM_MASTERS} in /etc/hosts"
        for NODE_NUM in $(seq $NUM_MASTERS); do
            local NODE_NAME=master${NODE_NUM}
            grep -q "\b${NODE_NAME}\b" /etc/hosts || ERRORS+="No entry for ${NODE_NAME} in /etc/hosts"
        done

        for NODE_NUM in $(seq $NUM_MASTERS); do
            local NODE_NAME=master${NODE_NUM}
            MAC_ADDR=$(ssh ${NODE_NAME} ip link | grep -E "eth|ens" -m 1 -A +1 | tail -1 | awk '{ print $2; }')
            echo $MAC_ADDR >> /tmp/iplink.addr
            echo "${NODE_NAME} $MAC_ADDR" >> /tmp/iplink.addr.nodes
        done
    fi

    ## -- CHECKS on worker node(s): -------------------------------------------------------------
    if [ $NUM_WORKERS -eq 1 ]; then
        MAC_ADDR=$(ssh worker1 ip link | grep -E "eth|ens" -m 1 -A +1 | tail -1 | awk '{ print $2; }')
        echo $MAC_ADDR >> /tmp/iplink.addr
        echo "worker1 $MAC_ADDR" >> /tmp/iplink.addr.nodes

        [ $VERBOSE -ne 0 ] && echo "Checking no swap is enabled on worker1"
        ssh worker1 mount | grep -i swap && ERRORS+="Swap is enabled on worker1 - disable using 'sudo swapoff -a'"

        [ $VERBOSE -ne 0 ] && echo "Checking presence of worker1 in /etc/hosts"
        grep -q "\bworker1\b" /etc/hosts || ERRORS+="No entry for worker1 in /etc/hosts"

        [ $VERBOSE -ne 0 ] && echo "Checking connectivity to worker1"
        ssh worker1 uptime || ERRORS+="Failed to connect to worker1"
    else
        [ $VERBOSE -ne 0 ] && echo "Checking no swap is enabled on worker{1..$NUM_WORKERS}"
        for NODE_NUM in $(seq $NUM_WORKERS); do
            local NODE_NAME=worker${NODE_NUM}
            mount | grep -i swap && ERRORS+="Swap is enabled on ${NODE_NAME} - disable using 'sudo swapoff -a'"
        done

        [ $VERBOSE -ne 0 ] && echo "Checking presence of worker{1..$NUM_WORKERS} in /etc/hosts"
        for NODE_NUM in $(seq $NUM_WORKERS); do
            local NODE_NAME=worker${NODE_NUM}
            grep -q "\b${NODE_NAME}\b" /etc/hosts || ERRORS+="No entry for ${NODE_NAME} in /etc/hosts"
        done

        [ $VERBOSE -ne 0 ] && echo "Checking connectivity to worker{1..$NUM_WORKERS}"
        for NODE_NUM in $(seq $NUM_WORKERS); do
            local NODE_NAME=worker${NODE_NUM}
            ssh ${NODE_NAME} uptime || ERRORS+="Failed to connect to ${NODE_NAME}"
        done

        for NODE_NUM in $(seq $NUM_MASTERS); do
            local NODE_NAME=worker${NODE_NUM}
            MAC_ADDR=$(ssh ${NODE_NAME} ip link | grep -E "eth|ens" -m 1 -A +1 | tail -1 | awk '{ print $2; }')
            echo $MAC_ADDR >> /tmp/iplink.addr
            echo "${NODE_NAME} $MAC_ADDR" >> /tmp/iplink.addr.nodes
        done
    fi

    # - ssh access to remote system as current user and sudo access
    if [ $NUM_WORKERS -eq 1 ]; then
        [ $VERBOSE -ne 0 ] && echo "Checking sudo access on worker1"
        ssh -qt worker1 sudo -i touch /TESTFILE || ERRORS+="Failed to touch file worker1:/TESTFILE"
        ssh -qt worker1 sudo rm -f    /TESTFILE || ERRORS+="Failed remove   file worker1:/TESTFILE"
    else
        [ $VERBOSE -ne 0 ] && echo "Checking presence of worker{1..$NUM_WORKERS} in /etc/hosts"
        for NODE_NUM in $(seq $NUM_WORKERS); do
            local NODE_NAME=worker${NODE_NUM}
            [ $VERBOSE -ne 0 ] && echo "Checking sudo access on ${NODE_NAME}"
            ssh -qt ${NODE_NAME} sudo -i touch /TESTFILE || ERRORS+="Failed to touch file ${NODE_NAME}:/TESTFILE"
            ssh -qt ${NODE_NAME} sudo rm -f    /TESTFILE || ERRORS+="Failed remove   file ${NODE_NAME}:/TESTFILE"
        done
    fi

    # - ssh access to remote system as current user and ssh back to master(1)
    if [ $NUM_WORKERS -eq 1 ]; then
        [ $VERBOSE -ne 0 ] && echo "Checking ssh from worker1 back to master"
        ssh -qt worker1 ssh $(hostname) hostname || ERRORS+="Failed to ssh from ${NODE_NAME} to master"
    else
        [ $VERBOSE -ne 0 ] && echo "Checking ssh from worker{1..$NUM_WORKERS} back to master"
        for NODE_NUM in $(seq $NUM_WORKERS); do
            local NODE_NAME=worker${NODE_NUM}
            [ $VERBOSE -ne 0 ] && echo "Checking ssh from ${NODE_NAME} back to master"
            ssh -qt ${NODE_NAME} ssh $(hostname) hostname || ERRORS+="Failed to ssh from ${NODE_NAME} to master"
        done
    fi

    ## -- CHECKS on all node(s): ---------------------------------------------------------------------
    DUPS=$(sort -n /tmp/iplink.addr | uniq -d | wc -l)
    [ "$DUPS" != "0" ] && echo -e "$DUPS duplicate MAC addresses seen in /tmp/iplink.addr.nodes:\n$(cat /tmp/iplink.addr.nodes)"

    ## -- RESULT: ------------------------------------------------------------------------------------
    [ -z "$ERRORS" ] && { echo "OK: Pre-requisite checks"; return 0; }

    echo "Errors were seen - pre-requsites were not matched:"
    echo $ERRORS
    return 1
}


## Main: ------------------------------------------------------------------------------

echo; echo "======== Performing Pre-requisite Checks =================="
CHECK_PREREQS || die "Failed pre-requisite tests"

echo; echo "======== Installing Kubernetes Packages ==================="
INSTALL_PACKAGES

CREATE_CLUSTER
INSTALL_CNI_CALICO
#echo "[$(date)/$(date +%s)]: setup-master Finished on $(hostname)"


