#!/bin/bash
/usr/local/sbin/kamailio -DD -ddd -E -e -m 256 -M 12 \
  -A KAM_IP_LOCAL=$(ip addr | grep 172 | awk '{print $2}' | cut -d '/' -f 1) \
  -A KAM_IP_PUBLIC=$(ip route get 8.8.8.8 | awk 'NR==1 {print $NF}')
