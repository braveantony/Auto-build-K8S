#!/bin/bash

# Debug mode
set -x

# Var
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
export HOSTNAME=$HOSTNAME
ALL_NODE=$(cat "${HOME}"/bin/mactohost | grep 'zip' | awk '{print $2}')
MASTER_NODE=$(cat "${HOME}"/bin/mactohost | grep 'zip' | awk '{print $2}' | grep 'm')
WORK_NODE=$(cat "${HOME}"/bin/mactohost | grep 'zip' | awk '{print $2}' | grep 'w')
VIP=$(cat "$script_dir"/init-config.yaml | grep "^controlP" | cut -d " " -f 2 | cut -d ":" -f 1)
CNI='https://raw.githubusercontent.com/projectcalico/calico/master/manifests/calico.yaml'
COUNT_MASTER_NODE=$(echo ${MASTER_NODE} | awk '{print NF}')
COUNT_WORK_NODE=$(echo ${WORK_NODE} | awk '{print NF}')

# check vars
check_vars() {
  var_names=("script_dir" "HOSTNAME" "ALL_NODE" "MASTER_NODE" "WORK_NODE" "COUNT_MASTER_NODE" "COUNT_WORK_NODE" "GWIF")
  for var_name in "${var_names[@]}"; do
      [ -z "${!var_name}" ] && echo "$var_name is unset." && exit 1
  done
  return 0
}
check_vars

# Assign a heredoc value to a variable with read useless use of cat
IFS='' read -r -d '' INSTALL_kubeadm_kubelet_kubectl <<'EOT'
if ! (sudo apk update &> /dev/null; sudo apk add kubeadm kubelet kubectl --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted &> /dev/null); then
  echo "$a install kubectl , kubeadm , kubelet failed" && exit 1
fi

if ! sudo rc-update add kubelet default &> /dev/null; then
  echo "$a setup kubelet failed !" && exit 1
fi
EOT

IFS='' read -r -d '' SET_BIGRED_AS_K8S_ADMIN <<'EOT'
mkdir -p $HOME/.kube; sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config; sudo chown $(id -u):$(id -g) $HOME/.kube/config
EOT

IFS='' read -r -d '' INSTALL_kubeadm_kubelet <<'EOT'
if ! sudo apk add kubeadm kubelet --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted &> /dev/null; then
  echo "$w install kubeadm , kubelet failed" && exit 1
fi

if ! sudo rc-update add kubelet default &> /dev/null; then
  echo "$w setup kubelet failed !" && exit 1
fi
EOT

IFS='' read -r -d '' SETUP_KUBE_VIP <<'EOT'
export KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")
alias kube-vip="sudo podman run --network host --rm ghcr.io/kube-vip/kube-vip:$KVVERSION"

sudo mkdir -p /etc/kubernetes/manifests/
${BASH_ALIASES[kube-vip]} manifest pod --interface $GWIF --vip $VIP --controlplane --arp --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
EOT

# 1. Install kubectl , kubeadm , kubelet
for a in $MASTER_NODE
do
  if ! ssh "$a" "${INSTALL_kubeadm_kubelet_kubectl}"; then
    exit 1
  fi
done

# 2. Set up kube-vip
if ssh localhost "export VIP=$VIP; export GWIF=$(ip r s | grep "^de" | cut -d ' ' -f 5); $SETUP_KUBE_VIP" &>/dev/null; then
  echo $?
  echo "Preparing mater nodes ok"
else
  echo $?
  echo "Preparing mater nodes Error" && exit 1
fi

# 3. Init Kubernetes
if [ "$COUNT_MASTER_NODE" -eq "1" ]; then
  if ! sed -i '/Endpoint/d' init-config.yaml; then
    echo "Setup init-config.yaml Error"
  fi
fi
cat "${script_dir}"/init-config.yaml | envsubst > "${script_dir}"/init-tmp-config.yaml && mv "${script_dir}"/init-tmp-config.yaml "${script_dir}"/init-config.yaml
sudo kubeadm init --upload-certs --config="${script_dir}"/init-config.yaml &> /dev/null
if [ "$?" == "0" ]; then
  echo "Your Kubernetes control-plane has initialized successfully!"
else
  echo "Your Kubernetes control-plane has initialized failed!" && exit 1
fi

# 4. 將 Linux bigred user 設成 K8S 管理者
if ! (mkdir -p "$HOME"/.kube; sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config; sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config); then
  echo "$(hostname) Set bigred as admin failed!" && exit 1
fi

# 5. 設定 K8S Master 可以執行 Pod
if ! cat "${script_dir}"/init-config.yaml | grep 'taints: \[\]' &> /dev/null; then
  kubectl taint node "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule- &> /dev/null
  if [ "$?" != "0" ]; then
    echo "node/"$(hostname)" untainted failed" && exit 1
  fi
fi

# 6. Install CNI
curl "$CNI" -o "${script_dir}/cni.yaml" &> /dev/null
[ ! -f "${script_dir}/cni.yaml" ] && echo "Download CNI package error" && exit 1
if kubectl apply -f "${script_dir}/cni.yaml" &> /dev/null; then
  echo "Installing CNI ok"
else
  echo "Installing CNI failed"
fi


# Joining more control-plane nodes
## var
certs=$(sudo kubeadm init phase upload-certs --upload-certs | tail -n 1)
JOIN_MASTER_NODE=$(echo "sudo $(sudo kubeadm token create --print-join-command) --control-plane --certificate-key ${certs}")
JOIN_WORKER_NODE=$(echo "sudo $(sudo kubeadm token create --print-join-command 2>/dev/null)")

for a in $MASTER_NODE
do
  [ "$COUNT_MASTER_NODE" -eq "1" ] && break
  [ "$a" == "$(hostname)" ] && continue

  ssh "$a" "$JOIN_MASTER_NODE" &> /dev/null
  if [ "$?" != "0" ]; then
    echo "$a node join failed" && exit 1
  fi

  ssh "$a" "$SET_BIGRED_AS_K8S_ADMIN"
  if [ "$?" != "0" ]; then
    echo "${a} Set bigred as admin failed!" && exit 1
  fi

  if ! cat "$HOME"/init-config.yaml | grep 'taints: \[\]' &> /dev/null; then
    kubectl taint node "$a" node-role.kubernetes.io/control-plane:NoSchedule- &> /dev/null
    if [ "$?" != "0" ]; then
      echo "node/"$a" untainted failed" && exit 1
    fi
  fi

  ssh "$a" "export VIP=$VIP; export GWIF=$(ip r s | grep "^de" | cut -d ' ' -f 5); $SETUP_KUBE_VIP" &>/dev/null
  [ "$?" == "0" ] && echo "Joining "$a" control-plane node ok" || (echo "Joining "$a" control-plane node Error" && exit 1)

done

for w in $WORK_NODE
do
  ssh "$w" "$INSTALL_kubeadm_kubelet"

  ssh "$w" "$JOIN_WORKER_NODE" &> /dev/null
  if [ "$?" != "0" ]; then
    echo "$w join failed" && exit 1
  fi

  kubectl label node "$w" node-role.kubernetes.io/worker= &> /dev/null
  [ "$?" == "0" ] && echo "Joining "$w" worker node ok" || (echo "Joining "$w" worker node failed" && exit 1)
done

#for x in $ALL_NODE
#do
#  ssh $x 'sudo reboot'
#done
