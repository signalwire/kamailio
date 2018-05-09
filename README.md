# Kamailio Edge Proxy #

Load balancing (round-robin) to a farm of FreeSwitch systems and routing the
traffic from FreeSwitch based on R-URI address.

Addresses of FreeSwitch systems must be added inside `etc/dispatcher.list` with
the group id `100`.

It requires Kamailio master branch to be cloned in this directory.

## Usage ##

Clone the required git repositories:

```
git clone https://github.com/signalwire/kamailio signalwire-kamailio
cd signalwire-kamailio
git clone https://github.com/kamailio/kamailio
```

Edit `etc/dispatcher.list` and add there the addresses for FreeSwitch systems.

Edit `docker/Dockerfile` and set the private (local) and public IP addresses to be used by Kamailio.

Build and run docker container.

```
docker build -t signalwire-kamailio-edgeproxy -f docker/Dockerfile .
docker run -p 5060:5060/udp signalwire-kamailio-edgeproxy
```

## Notes ##

  * UDP, TCP and TLS are enabled (testing so far was done for UDP)