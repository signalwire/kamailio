FROM signalwire/freeswitch-libs:debian-10 as intermediate

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes \
  flex libgeoip-dev libhiredis-dev lua-cjson-dev libunistring-dev xsltproc \
  liblua5.1-0-dev libunistring-dev libxml2-dev \
  && rm -rf /var/lib/apt/lists/*

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
RUN cp /usr/local/src/ruxc/include/ruxc.h /usr/local/src/ruxc/target/release/libruxc.a /usr/local/src/kamailio/src/modules/ruxc/ \
&& make -j`nproc --all` include_modules="app_lua tls outbound ipops db_redis ndb_redis rtimer mqueue permissions xhttp websocket nathelper kemix ruxc" cfg \
&& make -j`nproc --all` all && make install \
&& cd src/modules/tls && make install-tls-cert

### Production Image
FROM signalwire/freeswitch-base:debian-10
MAINTAINER Evan McGee <evan@signalwire.com>

ENV \
  CONFD_VERSION=0.16.0 \
  CONFD_SHA256=255d2559f3824dd64df059bdc533fd6b697c070db603c76aaf8d1d5e6b0cc334 \
  LC_ALL=en_US.utf-8 \
  TINI_VERSION=v0.19.0

# Add Tini
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

RUN apt-get update && apt-get -y install --no-install-recommends --no-install-suggests \
  dnsutils iproute2 curl locales apt-transport-https ca-certificates nano lua-cjson liblua5.1-0-dev \
  && locale-gen en_US en_US.UTF-8 && rm -rf /var/lib/apt/lists/* \
  && curl -L https://github.com/kelseyhightower/confd/releases/download/v${CONFD_VERSION}/confd-${CONFD_VERSION}-linux-amd64 -o /bin/confd \
  && sha256sum /bin/confd | grep ${CONFD_SHA256} \
  && chmod +x /tini \
  && chmod 500 /bin/confd \ 
  && git clone https://github.com/gperftools/gperftools.git\
  && cd gperftools && ./autogen.sh && ./configure && make -j`nproc` && make install && cd .. && rm -rf gperftools*
  
COPY --from=intermediate /usr/lib/libsignalwire_client.so.2 /usr/lib/libsignalwire_client.so.2
COPY --from=intermediate /usr/lib/libks.so.2 /usr/lib/libks.so.2

COPY --from=intermediate /usr/local/lib64/kamailio /usr/local/lib64/kamailio
COPY --from=intermediate /usr/local/lib64/kamailio/modules /usr/local/lib64/kamailio/modules
COPY --from=intermediate /usr/local/etc /usr/local/etc
COPY --from=intermediate /usr/local/sbin /usr/local/sbin

COPY tls/ /usr/local/etc/kamailio/tls
COPY etc/ /usr/local/etc/kamailio
COPY confd/ /etc/confd
COPY provisioning/docker-entrypoint.sh /docker-entrypoint.sh
COPY test/simple.sh /simple-test.sh

CMD ["/docker-entrypoint.sh"]
