#!/bin/bash

if [ "x${KAM_IP_PUBLIC}" == "x" ]; then
  KAM_IP_PUBLIC=$(dig +short myip.opendns.com @resolver1.opendns.com)
fi

if [[ ! -v CONFD_DISABLED ]]; then
  # Ensure secrets are pulled and present before starting
  until confd --onetime --backend vault --auth-type token --auth-token ${CONFD_AUTH_TOKEN} --node https://vault.signalwire.cloud --prefix="/kv"; do
    echo "Waiting for confd to pull initial secrets"
    sleep 5
  done

  confd --backend vault --auth-type token --auth-token ${CONFD_AUTH_TOKEN} --node https://vault.signalwire.cloud --prefix="/kv" &
fi

echo 65535 > /writeable-proc/sys/net/core/somaxconn
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so HEAPPROFILE=/tmp/heapprof /usr/local/sbin/kamailio -DD -dd -E -m 2048 -M 24 \
  -A KAM_IP_LOCAL=$(ip route get 1.1.1.1 | awk 'NR==1 {print $NF}') \
  -A KAM_IP_PUBLIC=${KAM_IP_PUBLIC} \
  -A KAM_IP_OTHER=$(ip addr | grep -Po '.+10.92.+\/16.+' | grep -Po 'inet \K[\d.]+') \
  -A KAM_CLUSTER_NONCE=\"$KAM_CLUSTER_NONCE\" \
  -A $KAMAILIO_LOCATION \
  --log-engine=json:acA
