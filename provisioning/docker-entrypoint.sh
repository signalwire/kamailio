#!/bin/bash
/usr/local/sbin/kamailio -DD -ddd -E -e -m 256 -M 12 \
  -A KAM_IP_LOCAL=$(ip route get 8.8.8.8 | awk 'NR==1 {print $NF}') \
  -A KAM_IP_PUBLIC=$(dig +short myip.opendns.com @resolver1.opendns.com) \
  -A KAM_IP_OTHER=$(ip addr | grep -Po '.+10.0.+\/24.+' | grep -Po 'inet \K[\d.]+')
