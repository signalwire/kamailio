FROM debian:stretch

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes apt-utils \
  autoconf gcc g++ make procps \
  coreutils ctags curl gawk gdb git jq lynx ngrep sed vim wget \
  bison \
  debhelper \
  dh-systemd \
  dpkg-dev \
  flex \
  libgeoip-dev \
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
WORKDIR /usr/local/src/kamailio
RUN make -j`nproc -all` include_modules="app_lua http_client tls outbound" cfg
RUN make -j`nproc -all` all
RUN make install
WORKDIR src/modules/tls
RUN make install-tls-cert


COPY etc/kamailio.cfg /usr/local/etc/kamailio/kamailio.cfg
COPY etc/kamailio-routing.lua /usr/local/etc/kamailio/kamailio-routing.lua
COPY etc/dispatcher.list /usr/local/etc/kamailio/dispatcher.list
COPY provisioning/docker-entrypoint.sh /docker-entrypoint.sh
WORKDIR /usr/local/src

# Add Tini
ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

CMD ["/docker-entrypoint.sh"]
