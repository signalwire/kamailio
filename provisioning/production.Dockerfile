FROM signalwire/freeswitch-libs as intermediate

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes \
  flex libgeoip-dev libhiredis-dev lua-cjson-dev libunistring-dev xsltproc \
  && rm -rf /var/lib/apt/lists/*

COPY kamailio /usr/local/src/kamailio
COPY src/modules/bladec /usr/local/src/kamailio/src/modules/bladec
WORKDIR /usr/local/src/kamailio
RUN make -j`nproc --all` include_modules="app_lua http_client tls outbound ipops db_redis ndb_redis bladec rtimer mqueue permissions xhttp websocket nathelper" cfg \
&& make -j`nproc --all` all && make install \
&& cd src/modules/tls && make install-tls-cert


FROM debian:stretch-slim
MAINTAINER Evan McGee <evan@signalwire.com>

# Add Tini
ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

RUN apt-get update && apt-get -y install --no-install-recommends --no-install-suggests \
  dnsutils iproute2 curl locales apt-transport-https ca-certificates nano \
  && locale-gen en_US en_US.UTF-8 && rm -rf /var/lib/apt/lists/* 

ENV LC_ALL en_US.utf-8

COPY --from=intermediate /lib/x86_64-linux-gnu /lib/x86_64-linux-gnu
COPY --from=intermediate /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu

COPY --from=intermediate /usr/lib/libsignalwire_client.so.1 /usr/lib/libsignalwire_client.so.1
COPY --from=intermediate /usr/lib/libks.so.1 /usr/lib/libks.so.1

COPY --from=intermediate /usr/local/lib64/kamailio /usr/local/lib64/kamailio
COPY --from=intermediate /usr/local/lib64/kamailio/modules /usr/local/lib64/kamailio/modules
COPY --from=intermediate /usr/local/etc /usr/local/etc
COPY --from=intermediate /usr/local/sbin /usr/local/sbin


COPY tls/ /usr/local/etc/kamailio/tls
COPY ca/ /usr/local/etc/kamailio/blade/ca
COPY etc/ /usr/local/etc/kamailio
COPY provisioning/docker-entrypoint.sh /docker-entrypoint.sh

CMD ["/docker-entrypoint.sh"]
