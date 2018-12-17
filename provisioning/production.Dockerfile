FROM signalwire/freeswitch-libs

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes apt-utils \
  autoconf gcc g++ make procps \
  coreutils ctags curl gawk gdb git jq lynx ngrep sed vim wget \
  bison \
  debhelper \
  dh-systemd \
  dpkg-dev \
  flex \
  libgeoip-dev \
  libhiredis-dev \
  liblua5.1-0-dev \
  lua-cjson-dev \
  libncurses5-dev \
  libpcre3-dev \
  libssl-dev \
  libunistring-dev \
  openssl \
  pkg-config \
  uuid-dev \
  xsltproc \
  zlib1g-dev \
  dnsutils \
  libcurl4-openssl-dev \
  libjemalloc-dev && rm -rf /var/lib/apt/lists/*

COPY kamailio /usr/local/src/kamailio
COPY src/modules/bladec /usr/local/src/kamailio/src/modules/bladec
WORKDIR /usr/local/src/kamailio
RUN make -j`nproc -all` include_modules="app_lua http_client tls outbound ipops db_redis ndb_redis bladec rtimer mqueue permissions xhttp websocket" cfg
RUN make -j`nproc -all` all
RUN make install
WORKDIR src/modules/tls
RUN make install-tls-cert


COPY etc/kamailio.cfg /usr/local/etc/kamailio/kamailio.cfg
COPY etc/kamailio-routing.lua /usr/local/etc/kamailio/kamailio-routing.lua
COPY etc/kamailio-bladec.cfg /usr/local/etc/kamailio/kamailio-bladec.cfg
COPY ca /usr/local/etc/kamailio/blade/ca
COPY etc/dispatcher.staging.list /usr/local/etc/kamailio/dispatcher.staging.list
COPY etc/dispatcher.us-west.list /usr/local/etc/kamailio/dispatcher.us-west.list
COPY etc/dispatcher.us-east.list /usr/local/etc/kamailio/dispatcher.us-east.list
COPY etc/dispatcher.eu.list /usr/local/etc/kamailio/dispatcher.eu.list
COPY etc/dispatcher.se-asia.list /usr/local/etc/kamailio/dispatcher.se-asia.list
COPY etc/tls.cfg /usr/local/etc/kamailio/tls.cfg
COPY tls/ /usr/local/etc/kamailio/tls
COPY provisioning/docker-entrypoint.sh /docker-entrypoint.sh
WORKDIR /usr/local/src

# Add Tini
ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

CMD ["/docker-entrypoint.sh"]
