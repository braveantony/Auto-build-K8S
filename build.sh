#!/bin/bash

# Debug mode
# set -x


# Var
ALL_NODE=$(cat "${HOME}"/bin/mactohost | grep 'zip' | awk '{print $2}')
MASTER_NODE=$(cat "${HOME}"/bin/mactohost | grep 'zip' | awk '{print $2}' | grep 'm')
WORK_NODE=$(cat "${HOME}"/bin/mactohost | grep 'zip' | awk '{print $2}' | grep 'w')


# Assign a heredoc value to a variable with read useless use of cat
IFS='' read -r -d '' KUBE_ADM_LET_CTL_INSTALL_COMMAND <<'EOT'
if sudo apk update &> /dev/null; sudo apk add kubeadm kubelet kubectl --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted &> /dev/null; then
  echo "$a kubectl , kubeadm , kubelet install ok"
else
  echo "$a kubectl , kubeadm , kubelet failed" && exit 1
fi

if sudo rc-update add kubelet default &> /dev/null; then
  echo "$a setup kubelet ok !"
else
  echo "$a setup kubelet failed !" && exit 1
fi
EOT

IFS='' read -r -d '' BIGRED_K8S_ADMIN_COMMAND <<'EOT'
mkdir -p $HOME/.kube; sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config; sudo chown $(id -u):$(id -g) $HOME/.kube/config
EOT

IFS='' read -r -d '' KUBE_ADM_LET_INSTALL_COMMAND <<'EOT'
if sudo apk add kubeadm kubelet --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted &> /dev/null; then
  echo "$w kubectl , kubeadm , kubelet install ok"
else
  echo "$w kubectl , kubeadm , kubelet failed" && exit 1
fi

if sudo rc-update add kubelet default &> /dev/null; then
  echo "$w setup kubelet ok !"
else
  echo "$w setup kubelet failed !" && exit 1
fi
EOT

# function
KUBE_VIP () {
  if export VIP=120.96.143.60; then
    echo "export VIP=$VIP ok"
  else
    echo "export VIP=$VIP failed"
  fi

  if export KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name"); then
    echo "export KVVERSION=$KVVERSION ok"
  else
    echo "export KVVERSION=$KVVERSION failed !" && exit 1
  fi

  if alias kube-vip="sudo podman run --network host --rm ghcr.io/kube-vip/kube-vip:$KVVERSION" &> /dev/null; then
    echo "alias kube-vip ok"
  else
    echo "alias kube-vip failed" && exit 1
  fi

  sudo mkdir -p /etc/kubernetes/manifests/
  ${BASH_ALIASES[kube-vip]} manifest pod \
      --interface $GWIF \
      --vip $VIP \
      --controlplane \
      --arp \
      --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml &> /dev/null

  if [ "$?" == "0" ]; then
    echo "kubevip static pods folder ok !"
  else
    echo "kubevip static pods folder failed !" && exit 1
  fi
}

# 1. 安裝 kubectl , kubeadm , kubelet
for a in $MASTER_NODE
do
  if ! ssh "$a" "${KUBE_ADM_LET_CTL_INSTALL_COMMAND}"; then
    exit 1
  fi
done

# 2. kube-vip (set up k2m1 node)
if KUBE_VIP; then
  echo "$hostname kube_vip ok"
else
  echo "$hostname kube_vip failed"
fi

# 3. 初始化 K8S
sudo kubeadm init --upload-certs --config="${HOME}"/init-config.yaml &> /dev/null
if [ "$?" == "0" ]; then
  echo "Your Kubernetes control-plane has initialized successfully!"
else
  echo "Your Kubernetes control-plane has initialized failed!" && exit 1
fi

# 4. 將 bigred 設成 K8S 管理者

if mkdir -p "$HOME"/.kube; sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config; sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config; then
  echo "$(hostname) Set bigred as admin ok!"
else
  echo "$(hostname) Set bigred as admin failed!" && exit 1
fi

# 5. 設定 K8S Master 可以執行 Pod
if ! cat "$HOME"/init-config.yaml | grep 'taints: \[\]' &> /dev/null; then
  kubectl taint node "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule- &> /dev/null
  if [ "$?" == "0" ]; then
    echo "node/"$(hostname)" untainted"
  else
    echo "node/"$(hostname)" untainted failed" && exit 1
  fi
fi

# 6. 安裝 Flannel 網路套件
if kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml &> /dev/null; then
  echo "CNI Flannel install ok"
else
  echo "CNI Flannel install failed"
fi

certs=$(sudo kubeadm init phase upload-certs --upload-certs | tail -n 1)
JOIN_MASTER_NODE=$(echo "sudo $(sudo kubeadm token create --print-join-command) --control-plane --certificate-key ${certs}")
JOIN_WORKER_NODE=$(echo "sudo $(sudo kubeadm token create --print-join-command 2>/dev/null)")

for a in $MASTER_NODE
do
  if [ "$a" == "$(hostname)" ]; then
    continue
  fi

  ssh "$a" "$JOIN_MASTER_NODE" &> /dev/null
  if [ "$?" == "0" ]; then
    echo "$a join ok"
  else
    echo "$a join failed" && exit 1
  fi

  ssh "$a" "$BIGRED_K8S_ADMIN_COMMAND"
  if [ "$?" == "0" ]; then
    echo "${a} Set bigred as admin ok!"
  else
    echo "${a} Set bigred as admin failed!" && exit 1
  fi

  if ! cat "$HOME"/init-config.yaml | grep 'taints: \[\]' &> /dev/null; then
    kubectl taint node "$a" node-role.kubernetes.io/control-plane:NoSchedule- &> /dev/null
    if [ "$?" == "0" ]; then
      echo "node/"$a" untainted"
    else
      echo "node/"$a" untainted failed" && exit 1
    fi
  fi
done

for w in $WORK_NODE
do
  ssh "$w" "$KUBE_ADM_LET_INSTALL_COMMAND"
  if [ "$?" == "0" ]; then
    echo "$w install kubelet kubeadm ok"
  else
    echo "$w install kubelet kubeadm failed" && exit 1
  fi

  ssh "$w" "$JOIN_WORKER_NODE" &> /dev/null
  if [ "$?" == "0" ]; then
    echo "$w join ok"
  else
    echo "$w join failed" && exit 1
  fi

  kubectl label node "$w" node-role.kubernetes.io/worker= &> /dev/null
done

for x in $ALL_NODE
do
  ssh $x 'sudo reboot'
done
