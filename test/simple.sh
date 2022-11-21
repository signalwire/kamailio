#!/bin/bash

echo Tools
apt update && apt install -yq procps curl netcat-openbsd net-tools redis-tools

function onexit {
  pkill kamailio
}
trap onexit exit

echo Start Kamailio
# docker-entrypoint.sh is really cute but relies on confd
/usr/local/sbin/kamailio -DD -dd -E -m 2048 -M 24 -A 'KAM_CLUSTER_NONCE="boo!"' -A 'KAM_IP_LOCAL=0.0.0.0' -A 'KAM_IP_PUBLIC=0.0.0.0' -A 'KAMAILIO_SIPTRACE_SOURCE_IP=0.0.0.0' -A 'KAMAILIO_DEVELOPMENT=true' --log-engine=json:acA &

echo Netstat
netstat -tunap

echo Ensure Kamailio is running
until curl -v http://127.0.0.1:5060/; do sleep 1; done

echo Add entry to registrar

nc -C -v -p 5080 localhost 5060 <<'EOT'
REGISTER bob@sip.swire.io SIP/2.0/tcp
Via: SIP/2.0/tcp 127.0.0.1:5080;branch=one
From: bob@sip.swire.io;tag=foo
To: bob@sip.swire.io
Call-ID: 123
CSeq: 1 REGISTER
Contact: sip:bob@127.0.0.1:5080
Content-Length: 0
Expires: 300

EOT
