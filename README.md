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
./docker-dev build
docker run -ti -p 60605:60605/udp signalwire/kamailio
```

## User Authentication And Location Services ##

User authentication and location services are enabled for the domains set in
the Lua table `DOMAINAUTH`. The key has to be the SIP domain in From header and
the value can be anything (recommended to be set to 1).

The password must be returned in a JSON document in `ha1` field, the value has
to be HA1 format. Kamailio does an HTTP post query to the URL set in `AUTHURL`
variable (see the Lua script). Kamailio sends in the HTTP post query a JSON
with username and domain, like:

```
{
  "username": "alice",
  "domain": "whatever.com"
}
```

Expected data in the response:

```
{
  "ha1": "__the_md5_string_"
}
```

The HA1 can be computed in command line with:


HA1=`echo -n "$USERNAME:$REALM:$PASSWORD" | md5sum | awk '{ print $1 }'`

```

### Dependencies ###

  * lua-cjson - used to parse the JSON data inside Lua script

## Redis Backend ##

For `permissions` module, add records like:

```
hmset address:entry::1 grp 1 ip_addr "127.0.0.1" mask 32 port 0
```

The key `address:entry::1` must have the prefix `address:entry::`, then the
suffix doesn't really matter, it just has to make the key unique for each record.

For routing users to specific instances, add records like:

```
set routeto:alice@127.0.0.1 500
# or
set routeto:alice@127.0.0.1 sip:127.0.0.1:5080
```

The first variant is routing calls from alice via dispatcher group 500, the
second variant is setting the next hop address directly, without using dispatcher.

## Notes ##

  * UDP, TCP and TLS are enabled (testing so far was done for UDP)
