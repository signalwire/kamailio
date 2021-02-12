FROM signalwire/freeswitch-libs as intermediate

ENV \
  CONFD_VERSION=0.16.0 \
  CONFD_SHA256=255d2559f3824dd64df059bdc533fd6b697c070db603c76aaf8d1d5e6b0cc334

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes \
  flex libgeoip-dev libhiredis-dev lua-cjson-dev libunistring-dev xsltproc dnsutils \
  && rm -rf /var/lib/apt/lists/* \
  && curl -L https://github.com/kelseyhightower/confd/releases/download/v${CONFD_VERSION}/confd-${CONFD_VERSION}-linux-amd64 -o /bin/confd \
  && sha256sum /bin/confd | grep ${CONFD_SHA256}

COPY kamailio /usr/local/src/kamailio
COPY src/modules/bladec /usr/local/src/kamailio/src/modules/bladec
WORKDIR /usr/local/src/kamailio
RUN make -j`nproc -all` include_modules="app_lua http_client tls outbound ipops db_redis ndb_redis bladec rtimer mqueue permissions xhttp websocket nathelper kemix" cfg
RUN make -j`nproc -all` all
RUN make install
WORKDIR src/modules/tls
RUN make install-tls-cert

COPY etc/ /usr/local/etc/kamailio
COPY confd /etc/confd
COPY provisioning/docker-entrypoint.sh /docker-entrypoint.sh
WORKDIR /usr/local/src

# Add Tini
ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini \
    && chmod 500 /bin/confd
ENTRYPOINT ["/tini", "--"]

CMD ["/docker-entrypoint.sh"]
