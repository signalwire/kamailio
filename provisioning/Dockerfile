FROM signalwire/freeswitch-libs as intermediate

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes \
  flex libgeoip-dev libhiredis-dev lua-cjson-dev libunistring-dev xsltproc dnsutils \
  && rm -rf /var/lib/apt/lists/*

COPY kamailio /usr/local/src/kamailio
COPY src/modules/bladec /usr/local/src/kamailio/src/modules/bladec
WORKDIR /usr/local/src/kamailio
RUN make -j`nproc -all` include_modules="app_lua http_client tls outbound ipops db_redis ndb_redis bladec rtimer mqueue permissions xhttp websocket nathelper" cfg
RUN make -j`nproc -all` all
RUN make install
WORKDIR src/modules/tls
RUN make install-tls-cert

COPY etc/ /usr/local/etc/kamailio
COPY provisioning/docker-entrypoint.sh /docker-entrypoint.sh
WORKDIR /usr/local/src

# Add Tini
ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

CMD ["/docker-entrypoint.sh"]
