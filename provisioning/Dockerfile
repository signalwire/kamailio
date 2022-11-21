FROM signalwire/freeswitch-libs:debian-10 as intermediate

ENV \
  CONFD_VERSION=0.16.0 \
  CONFD_SHA256=255d2559f3824dd64df059bdc533fd6b697c070db603c76aaf8d1d5e6b0cc334

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes \
  flex libgeoip-dev libhiredis-dev lua-cjson-dev libunistring-dev xsltproc dnsutils libgoogle-perftools-dev \
  liblua5.1-0-dev libunistring-dev libxml2-dev gdb \
  netbase \
  && rm -rf /var/lib/apt/lists/* \
  && curl -L https://github.com/kelseyhightower/confd/releases/download/v${CONFD_VERSION}/confd-${CONFD_VERSION}-linux-amd64 -o /bin/confd \
  && sha256sum /bin/confd | grep ${CONFD_SHA256}

# Build Rust ruxc
#--------
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl https://sh.rustup.rs -sSf | \
   sh -s -- --default-toolchain stable -y

COPY ruxc /usr/local/src/ruxc
WORKDIR /usr/local/src/ruxc
RUN cargo build --release
#--------

# Build Kamailio
COPY kamailio /usr/local/src/kamailio
WORKDIR /usr/local/src/kamailio
RUN cp /usr/local/src/ruxc/include/ruxc.h /usr/local/src/ruxc/target/release/libruxc.a /usr/local/src/kamailio/src/modules/ruxc/ 
RUN make -j`nproc -all` include_modules="app_lua tls outbound ipops db_redis ndb_redis rtimer mqueue permissions xhttp websocket nathelper kemix ruxc" cfg
RUN make -j`nproc -all` all
RUN make install
WORKDIR src/modules/tls
RUN make install-tls-cert

COPY etc/ /usr/local/etc/kamailio
COPY confd /etc/confd
COPY provisioning/docker-entrypoint.sh /docker-entrypoint.sh
WORKDIR /usr/local/src

# Add Tini
ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini \
    && chmod 500 /bin/confd
ENTRYPOINT ["/tini", "--"]

CMD ["/docker-entrypoint.sh"]
