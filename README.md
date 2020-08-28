# training-resources

Public scripts and YAML files for use in my trainings &amp; workshops

## Kubernetes

#### INSTALL_K8S_UBUNTU.sh

A Kubernetes installation script which
- checks pre-requisites are already satsified on all nodes
  - swap off
  - password-less sudo
  - master/worker entries in /etc/hosts
  - password-less ssh between master and all other nodes
  - password-less ssh between all other nodes and master
- Installs Docker, Kubectl/Kubeadm/Kubelet Ubuntu packages
- Creates the cluster
  - Performs kubeadm init
  - TODO: Performs kubeadm join on all master nodes
  - Performs kubeadm join on all worker nodes
  - Installs the Calico CNI

This script is intended to facilitate fast cluster setup in circumstances where the student does not need to understand the installation itself.

