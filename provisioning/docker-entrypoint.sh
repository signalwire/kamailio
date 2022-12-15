#!/bin/bash
prep_term()
{
    unset term_child_pid
    unset term_kill_needed
    trap 'handle_term' TERM INT
}

handle_term()
{
    if [ "${term_child_pid}" ]; then
        kill -TERM "${term_child_pid}" 2>/dev/null
    else
        term_kill_needed="yes"
    fi
}

wait_term()
{
    term_child_pid=$!
    if [ "${term_kill_needed}" ]; then
        kill -TERM "${term_child_pid}" 2>/dev/null
    fi
    wait ${term_child_pid}
    trap - TERM INT
    wait ${term_child_pid}
}

if [ ! -z "${KAMAILIO_PROFILING}" ]; then
  export LD_PRELOAD=/usr/local/lib/libtcmalloc.so
  export HEAPPROFILE=/tmp/heapprof
fi

if [ "x${KAM_IP_PUBLIC}" == "x" ]; then
  export KAM_IP_PUBLIC=$(dig +short myip.opendns.com @resolver1.opendns.com)
fi
echo $KAM_IP_PUBLIC > /etc/.healthcheck_public_ip

VAULT_CERT_NAME=${VAULT_CERT_NAME:-signalwire.com}
find /etc/confd/ -type f -exec sed -i "s|VAULT_CERT_NAME|$VAULT_CERT_NAME|g" {} \;

if [[ ! -v CONFD_DISABLED ]]; then
  # Ensure secrets are pulled and present before starting
  until confd --onetime --backend vault --auth-type token --auth-token ${CONFD_AUTH_TOKEN} --node https://vault.signalwire.cloud --prefix="/kv"; do
    echo "Waiting for confd to pull initial secrets"
    sleep 5
  done

  confd --backend vault --auth-type token --auth-token ${CONFD_AUTH_TOKEN} --node https://vault.signalwire.cloud --prefix="/kv" &
fi

#Set the source ip for HEP packets
if [[ ! -z "${KAMAILIO_SIPTRACE_URI}" ]]; then
   export KAMAILIO_SIPTRACE_SOURCE_IP=$(ip route get $(dig +short $(echo ${KAMAILIO_SIPTRACE_URI} | cut -d: -f2)) | sed 's/^.*src \([^ ]*\).*$/\1/;q')
fi

# NodeId used in the registrar
# This cannot be computed inside kamailio-routing.lua because the script is
# executed multiple times (in different threads) for the same instance.
if [ "x${REGISTRAR_NODEID}" == "x" ]; then
  export REGISTRAR_NODEID="kam-${HOSTNAME}-$(date '+%Y%m%dT%H%M%S%N')"
fi

if [ "x${REGISTRAR_AUTH}" == "x" ]; then
  export REGISTRAR_AUTH=$( echo -n "${REGISTRAR_USERNAME}:${REGISTRAR_PASSWORD}" | base64 -w0 )
fi

echo 65535 > /writeable-proc/sys/net/core/somaxconn
prep_term
  /usr/local/sbin/kamailio -DD -dd -E -m 2048 -M 24 \
    -A KAM_IP_LOCAL=$(ip route get 1.1.1.1 | sed 's/^.*src \([^ ]*\).*$/\1/;q') \
    -A KAM_IP_PUBLIC=${KAM_IP_PUBLIC} \
    ${KAMAILIO_SIPTRACE_URI:+-A KAMAILIO_SIPTRACE_URI=\"$KAMAILIO_SIPTRACE_URI\"} \
    ${KAMAILIO_SIPTRACE_SOURCE_IP:+-A KAMAILIO_SIPTRACE_SOURCE_IP=$KAMAILIO_SIPTRACE_SOURCE_IP} \
    -A KAM_IP_OTHER=$(ip addr | grep -Po '.+10.92.+\/16.+' | grep -Po 'inet \K[\d.]+') \
    -A KAM_CLUSTER_NONCE=\"$KAM_CLUSTER_NONCE\" \
    -A $KAMAILIO_LOCATION \
    --log-engine=json:acA &
wait_term
