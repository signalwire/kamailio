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

prep_term
echo 65535 > /writeable-proc/sys/net/core/somaxconn
/usr/local/sbin/kamailio -DD -dd -E -e -m 256 -M 12 \
  -A KAM_IP_LOCAL=$(ip route get 1.1.1.1 | awk 'NR==1 {print $NF}') \
  -A KAM_IP_PUBLIC=$(dig +short myip.opendns.com @resolver1.opendns.com) \
  -A KAM_IP_OTHER=$(ip addr | grep -Po '.+10.92.+\/16.+' | grep -Po 'inet \K[\d.]+') \
  $KAMAILIO_LOCATION
wait_term
