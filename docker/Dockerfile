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
  libncurses5-dev \
  libpcre3-dev \
  libssl-dev \
  libunistring-dev \
  openssl \
  pkg-config \
  uuid-dev \
  xsltproc \
  zlib1g-dev

COPY kamailio /usr/local/src/kamailio
WORKDIR /usr/local/src/kamailio
RUN make include_modules="app_lua tls" cfg
RUN make all
RUN make install
WORKDIR src/modules/tls
RUN make install-tls-cert


COPY etc/kamailio.cfg /usr/local/etc/kamailio/kamailio.cfg
COPY etc/kamailio-routing.lua /usr/local/etc/kamailio/kamailio-routing.lua
COPY etc/dispatcher.list /usr/local/etc/kamailio/dispatcher.list
WORKDIR /usr/local/src

ENTRYPOINT ["/usr/local/sbin/kamailio"]
CMD ["-DD", "-ddd", "-E", "-e", "-m", "256", "-M", "12", "-A", "KAM_IP_LOCAL=172.17.0.2", "-A", "KAM_IP_PUBLIC=192.168.178.75"]
