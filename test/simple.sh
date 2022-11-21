#!/bin/bash

# Hint: to test locally try
# docker run -it -p 5060:5060 -v $PWD/test/simple.sh:/simple-test.sh  signalwire/kamailio:production-pre /simple-test.sh

echo Tools
apt update && apt install -yq procps curl netcat-openbsd net-tools redis-tools

function onexit {
  pkill kamailio
}
trap onexit exit

HA1="goodgoodgood"

# echo Start authorization agent
function http_response {
  cat <<TEXT
HTTP/1.1 200 OK
Date: $(date -R)
Content-Type: application/json
Connection: close
Server: nc
Content-Length: 46

{"project_id":"projid","ha1":"$HA1"}
TEXT
}

while true; do http_response | nc -l -q 0 -C 127.0.0.1 8080; echo; done &
curl -v --fail http://127.0.0.1:8080/authorize --data '{}' || exit 1
curl -v --fail http://127.0.0.1:8080/authorize --data '{}' || exit 1

echo Start Kamailio
# docker-entrypoint.sh is really cute but relies on confd
export KAMAILIO_AUTHORIZATION_URL="http://127.0.0.1:8080/authorize"
/usr/local/sbin/kamailio \
  -DD -dd -E -m 2048 -M 24 \
  -A 'KAM_CLUSTER_NONCE="boo!"' \
  -A 'KAM_IP_LOCAL=127.0.0.1' \
  -A 'KAM_IP_PUBLIC=127.0.0.1' \
  -A 'KAMAILIO_SIPTRACE_SOURCE_IP=0.0.0.0' \
  -A 'KAMAILIO_DEVELOPMENT=true' \
  --log-engine=json:acA &

echo Ensure Kamailio is running
until curl -v http://127.0.0.1:5060/; do sleep 1; done

echo Netstat
netstat -tunap

echo Add entry to registrar
URI="sip:bob@sip.swire.io"

nc -C -v -q 1 -p 5080 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5080;branch=one
From: <sip:bob@sip.swire.io>;tag=foo
To: <sip:bob@sip.swire.io>
Call-ID: 123
CSeq: 1 REGISTER
Contact: sip:bob@127.0.0.1:5080
Content-Length: 0
Expires: 300

EOT

sleep 1
cat /tmp/response

NONCE=$(grep nonce /tmp/response | sed -e 's/^.*nonce="//' | sed -e 's/".*$//')
echo " ---------    NONCE = $NONCE  ----------      "
TO=$(grep To: /tmp/response)

curl -v --fail http://127.0.0.1:8080/authorize --data '{}' || exit 1

HA2=$( echo -n "REGISTER:$URI" | md5sum | cut -b -32 )
KD=$( echo -n "$HA1:$NONCE:$HA2" | md5sum | cut -b -32 )

nc -C -v -q 1 -p 5081 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5080;branch=one
From: <sip:bob@sip.swire.io>;tag=foo
To: <sip:bob@sip.swire.io>
Call-ID: 124
CSeq: 1 REGISTER
Contact: sip:bob@127.0.0.1:5080
Content-Length: 0
Expires: 300
Authorization: Digest realm="sip.swire.io", nonce="$NONCE", uri="$URI", qop=auth, response="${KD}"

EOT

sleep 1
cat /tmp/response

sleep 2
