#!/bin/bash

# Hint: to test locally try
# docker run -it -v $PWD/test/simple.sh:/simple-test.sh  signalwire/kamailio:production-pre /simple-test.sh

echo Tools
apt update && apt install -yq procps curl netcat-openbsd net-tools redis-tools jq

function onexit {
  pkill kamailio
}
trap onexit exit

# Must be 32 characters, Kamailio doesn't check the length and assumes 32
HA1="verygoodverygoodverygoodverygood"

echo Start authorization mock agent
function http_response {
  cat <<TEXT
HTTP/1.1 200 OK
Date: $(date -R)
Content-Type: application/json
Connection: close
Server: nc
Content-Length: 66

{"project_id":"projid","ha1":"$HA1"}
TEXT
}

# Fake webserver
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

echo '------------ REGISTER -----------'

echo Add entry to registrar
URI="sip:bob@sip.swire.io"
A2="REGISTER:$URI"
HA2=$( echo -n "${A2}" | md5sum | cut -b -32 )

nc -C -v -q 1 -p 5080 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5080;branch=one
From: <sip:bob@sip.swire.io>;tag=foo1
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

## Verify our webserver is still running
# curl -v --fail http://127.0.0.1:8080/authorize --data '{}' || exit 1

A3="$HA1:$NONCE:$HA2"
KD=$( echo -n "${A3}" | md5sum | cut -b -32 )

echo
echo "HA1=${HA1} A2=${A2} HA2=${HA2} A3=${A3} KD=${KD} NONCE=${NONCE} URI=${URI}"
echo

nc -C -v -q 1 -p 5081 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5081;branch=two
From: <sip:bob@sip.swire.io>;tag=foo1
To: <sip:bob@sip.swire.io>
Call-ID: 124
CSeq: 1 REGISTER
Contact: sip:bob@127.0.0.1:5081
Content-Length: 0
Expires: 300
Authorization: Digest username="bob", realm="sip.swire.io", nonce="${NONCE}", uri="${URI}", response="${KD}", algorithm=md5

EOT

sleep 1
cat /tmp/response

echo Check on Redis
redis-cli -h registrar-redis GET bob@projid || exit 1

echo Confirm with registrar access
curl -f -v $(echo "${REGISTRAR_URI}" | sed -e 's/sip/query/')projid/bob |\
  jq -e '.routes | length == 1' || exit 1

echo '------------ un-REGISTER -----------'

nc -C -v -q 1 -p 5082 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5082;branch=three
From: <sip:bob@sip.swire.io>;tag=foo2
To: <sip:bob@sip.swire.io>
Call-ID: 993
CSeq: 1 REGISTER
Contact: *
Content-Length: 0
Expires: 0

EOT

sleep 1
cat /tmp/response

NONCE=$(grep nonce /tmp/response | sed -e 's/^.*nonce="//' | sed -e 's/".*$//')
A3="$HA1:$NONCE:$HA2"
KD=$( echo -n "${A3}" | md5sum | cut -b -32 )

nc -C -v -q 1 -p 5083 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5083;branch=four
From: <sip:bob@sip.swire.io>;tag=foo2
To: <sip:bob@sip.swire.io>
Call-ID: 994
CSeq: 1 REGISTER
Contact: *
Content-Length: 0
Expires: 0
Authorization: Digest username="bob", realm="sip.swire.io", nonce="${NONCE}", uri="${URI}", response="${KD}", algorithm=md5

EOT

sleep 1
cat /tmp/response

redis-cli -h registrar-redis GET bob@projid

curl -v $(echo "${REGISTRAR_URI}" | sed -e 's/sip/query/')projid/bob 2>&1 |\
  grep '404 Not Found' || exit 1


echo '--------- automatic un-REGISTER ------'

nc -C -v -q 1 -p 5084 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5084;branch=five
From: <sip:bob@sip.swire.io>;tag=foo3
To: <sip:bob@sip.swire.io>
Call-ID: 773
CSeq: 1 REGISTER
Contact: sip:bob@127.0.0.1:5084
Content-Length: 0
Expires: 7

EOT

sleep 1
cat /tmp/response

NONCE=$(grep nonce /tmp/response | sed -e 's/^.*nonce="//' | sed -e 's/".*$//')

A3="$HA1:$NONCE:$HA2"
KD=$( echo -n "${A3}" | md5sum | cut -b -32 )

nc -C -v -q 1 -p 5085 127.0.0.1 5060 >/tmp/response <<EOT
REGISTER $URI SIP/2.0
Via: SIP/2.0/TCP 127.0.0.1:5081;branch=six
From: <sip:bob@sip.swire.io>;tag=foo3
To: <sip:bob@sip.swire.io>
Call-ID: 774
CSeq: 1 REGISTER
Contact: sip:bob@127.0.0.1:5085
Content-Length: 0
Expires: 7
Authorization: Digest username="bob", realm="sip.swire.io", nonce="${NONCE}", uri="${URI}", response="${KD}", algorithm=md5

EOT

sleep 1
cat /tmp/response

echo Confirm with registrar access
curl -f -v $(echo "${REGISTRAR_URI}" | sed -e 's/sip/query/')projid/bob |\
  jq -e '.routes | length == 1' || exit 1

# Should automatically unregister
sleep 20
curl -v $(echo "${REGISTRAR_URI}" | sed -e 's/sip/query/')projid/bob 2>&1 |\
  grep '404 Not Found' || exit 1

sleep 2
