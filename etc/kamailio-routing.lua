-- Kamailio - equivalent of routing blocks in Lua
--
-- KSR - the new dynamic object exporting Kamailio functions (kemi)
-- sr - the old static object exporting Kamailio functions
--

-- Relevant remarks:
--  * do not execute Lua 'exit' - that will kill Lua interpreter which is
--  embedded in Kamailio, resulting in killing Kamailio
--  * use KSR.x.exit() to trigger the stop of executing the script
--  * KSR.drop() is only marking the SIP message for drop, but doesn't stop
--  the execution of the script. Use KSR.x.exit() after it or KSR.x.drop()
--

local cjson = require "cjson"

-- global variables to enable/disable some features
WITH_ANTIFLOOD=true
WITH_AUTHCACHE=true
WITH_BLADENOTIFY = os.getenv("KAMAILIO_WITH_BLADENOTIFY") or true
WITH_REDISROUTE=false

-- global variables corresponding to defined values (e.g., flags) in kamailio.cfg
FLT_ACC=1
FLT_ACCMISSED=2
FLT_ACCFAILED=3
FLT_NATS=5
FLT_BRANCHDROP=15
FLT_AUTH_XKEYS=16
FLT_PROUTETO=17
FLT_GOT_AUTH_XKEYS=18

FLB_NATB=6
FLB_NATSIPPING=7
FLB_CLASSIC=8
FLB_WEBRTC=9

AUTH_XKEYS_TIMEFRAME=300

AUTHURL=os.getenv('KAMAILIO_AUTHORIZATION_URL')
-- AUTHURL="https://api.swire.io/api/provider_callback/kamailio/authorize"

-- Base URI for the registrar HTTP methods; make sure it finishes with `/sip/`
-- typically `http://registrar:port/sip/`
REGISTRAR_URI=os.getenv('REGISTRAR_URI')

-- Base64-encoded Basic Authorization content
REGISTRAR_AUTH=os.getenv('REGISTRAR_AUTH')

function char_to_hex(c)
  return string.format("%%%02X", string.byte(c))
end
-- this is https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/encodeURIComponent
function encode_uri_component(component)
  return string.gsub(component, "([^A-Za-z0-9_.!~*'()-])", char_to_hex)
end
function build_registrar_uri(projedId,resourceId)
  return REGISTRAR_URI..encode_uri_component(projedId).."/"..encode_uri_component(resourceId)
end

application_json_header = "Content-Type: application/json\r\n"
basic_authorization_header = "Authorization: Basic " .. REGISTRAR_AUTH .. "\r\n"
connection_close_header = "Connection: close\r\n"

auth_http_headers = application_json_header .. connection_close_header
registrar_http_headers = application_json_header .. basic_authorization_header .. connection_close_header

var_hres = "$var(hres)";


-- Node ID used in the registrar
REGISTRAR_NODEID=os.getenv('REGISTRAR_NODEID')

-- Special domain authorization for CNAME'd domains
DOMAINAUTH= {}

-- list of carrier IPs that require us to send 600/603 to reject calls
REJECT_600_IPS={
    -- Bandwidth
    "67.231.1.188/32",
    "67.231.4.138/32",
    "67.231.4.70/32",
    "67.231.3.4/32",
    -- Bandwidth TLS Trunk Group
    "67.231.4.92/32",
    "67.231.3.208/32"
}

-- list of addresses to allow traffic from without user auth
-- must have subnet mask (CIDR notation - use /32 for single ip addr)
ALLOWADDR={
    -- DT Leipzig
    "194.25.206.99/32",
    "194.25.206.100/32",
    "194.25.206.101/32",
    "194.25.206.102/32",
    "194.25.206.103/32",
    "194.25.206.104/32",
    "194.25.206.105/32",
    "194.25.206.106/32",
    "194.25.206.107/32",
    "194.25.206.108/32",
    "194.25.206.109/32",
    "194.25.206.110/32",
    "194.25.206.111/32",
    "194.25.206.112/32",
    "194.25.206.113/32",
    "194.25.206.114/32",
    "194.25.206.115/32",
    "194.25.206.116/32",
    "194.25.206.117/32",
    "194.25.206.118/32",
    "194.25.206.119/32",
    "194.25.206.120/32",
    "194.25.206.121/32",
    "194.25.206.122/32",
    -- DT Neuss
    "194.25.206.195/32",
    "194.25.206.196/32",
    "194.25.206.197/32",
    "194.25.206.198/32",
    "194.25.206.199/32",
    "194.25.206.200/32",
    "194.25.206.201/32",
    "194.25.206.202/32",
    "194.25.206.203/32",
    "194.25.206.204/32",
    "194.25.206.205/32",
    "194.25.206.206/32",
    "194.25.206.207/32",
    "194.25.206.208/32",
    "194.25.206.209/32",
    "194.25.206.210/32",
    "194.25.206.211/32",
    "194.25.206.212/32",
    "194.25.206.213/32",
    "194.25.206.214/32",
    "194.25.206.215/32",
    "194.25.206.216/32",
    "194.25.206.217/32",
    "194.25.206.218/32",
    -- DT Frankfurt
    "194.25.206.227/32",
    "194.25.206.228/32",
    "194.25.206.229/32",
    "194.25.206.230/32",
    "194.25.206.231/32",
    "194.25.206.232/32",
    "194.25.206.233/32",
    "194.25.206.234/32",
    "194.25.206.235/32",
    "194.25.206.236/32",
    "194.25.206.237/32",
    "194.25.206.238/32",
    "194.25.206.239/32",
    "194.25.206.240/32",
    "194.25.206.241/32",
    "194.25.206.242/32",
    "194.25.206.243/32",
    "194.25.206.244/32",
    "194.25.206.245/32",
    "194.25.206.246/32",
    "194.25.206.247/32",
    "194.25.206.248/32",
    "194.25.206.249/32",
    "194.25.206.250/32",
    -- DT Nurnberg
    "194.25.206.67/32",
    "194.25.206.68/32",
    "194.25.206.69/32",
    "194.25.206.70/32",
    "194.25.206.71/32",
    "194.25.206.72/32",
    "194.25.206.73/32",
    "194.25.206.74/32",
    "194.25.206.75/32",
    "194.25.206.76/32",
    "194.25.206.77/32",
    "194.25.206.78/32",
    "194.25.206.79/32",
    "194.25.206.80/32",
    "194.25.206.81/32",
    "194.25.206.82/32",
    "194.25.206.83/32",
    "194.25.206.84/32",
    "194.25.206.85/32",
    "194.25.206.86/32",
    "194.25.206.87/32",
    "194.25.206.88/32",
    "194.25.206.89/32",
    "194.25.206.90/32",
    -- DT New York
    "80.149.27.66/32",
    "80.149.27.67/32",
    "80.149.27.68/32",
    "80.149.27.69/32",
    "80.149.27.70/32",
    "80.149.27.71/32",
    "80.149.27.72/32",
    "80.149.27.73/32",
    "80.149.27.74/32",
    "80.149.27.75/32",
    "80.149.27.76/32",
    "80.149.27.77/32",
    "80.149.27.78/32",
    "80.149.27.79/32",
    "80.149.27.80/32",
    "80.149.27.81/32",
    "80.149.27.82/32",
    "80.149.27.83/32",
    "80.149.27.84/32",
    "80.149.27.85/32",
    "80.149.27.86/32",
    -- DT Dallas
    "80.157.16.66/32",
    "80.157.16.67/32",
    "80.157.16.68/32",
    "80.157.16.69/32",
    "80.157.16.70/32",
    "80.157.16.71/32",
    "80.157.16.72/32",
    "80.157.16.73/32",
    "80.157.16.74/32",
    "80.157.16.75/32",
    "80.157.16.76/32",
    "80.157.16.77/32",
    "80.157.16.78/32",
    "80.157.16.79/32",
    "80.157.16.80/32",
    -- DT Twilio Frankfurt
    "35.156.191.128/30"
};

-- list of freeswitch addresses to allow traffic from without user auth
-- must have subnet mask (CIDR notation - use /32 for single ip addr)
FSADDR={
    -- OVH GRA9
    "57.128.79.18/32",
    "51.210.146.81/32",
    "57.128.78.45/32"
};

-- list of user agents to block as being likely spam/attack vectors
BAD_USER_AGENTS={
    "sipcli",
    "sipvicious",
    "sip-scan",
    "sipsak",
    "sundayddr",
    "friendly",
    "iWar",
    "SIVuS",
    "Gulp",
    "sipv",
    "smap",
    "friendly",
    "VaxIPUserAgent",
    "VaxSIPUserAgent",
    "siparmyknife",
    "Test Agent",
    "xcv123",
    "pplsip",
    "sipscan",
    "custom",
    "sipptk",
    "VaxSip"
};

-- List of domains to skip for Pike Blocking - must be the beginning of the URL "To" domain
-- Note: to specify exact subdomain, you must Lua-escape the initial hyphen (e.g. [-])
SKIP_ANTIFLOOD_DOMAINS = {
    "robokiller[-]",
    "servicetitanproduction[-]",
    "servicetitanstaging[-]",
    "counterpath[-]",
    "soundofdata[-]loadtest[-]",
    "dev[-]",
    "us%..+%.carriers",
    "eu%.carriers",
    "australia%.carriers",
    "cust%.%w+%.auth%.bandwidth%.com$",
    "dt[-]"
};

-- List of IP ranges to skip for Pike Blocking 
-- Prevents Kamailio for denying service from internal IPs
SKIP_ANTIFLOOD_IPS = {
  "172.17.0.1/24",
  "172.18.0.1/24",
  -- DT SIP IPs
  "194.25.206.44/32",
  "194.25.206.172/32"
};

-- List of domains to use Stable Routing
-- Note: to specify exact subdomain, you must Lua-escape the initial hyphen (e.g. [-])
STABLE_ROUTING_DOMAINS = {
};

-- list of ip addresses that have the project id mapped statically
PROJECTIPID = {}
PROJECTIPID["127.0.0.1"] = "eu-signalwire.localhost"

local g_crt_projectid = ""

-- list of subdomains for pass through forwarding (no auth)
-- * values with leading '.' (dot) to avoid mismatching in 'ends-with'
SUBDOMAIN_PASSTHROUGH = {
    ".dapp.eu-signalwire.com"
}

-- parse out domain, port, and options from supplied subdomain
-- expects sdomain[:port][;options]
function ksr_parse_sdomain(sdomain)
    local domain = ''
    local rest = ''
    local port = ''
    local options = ''
    domain, rest = sdomain:match("([^;:]*)[:;]?(.*)")
    if not(rest == '') then
      port, options = rest:match("(%d*);?(.*)")
    end

    return domain, port, options
end

-- match (ends-with) the parameter against SUBDOMAIN_PASSTHROUGH list
function ksr_domain_pass_thorugh(sdomain)
    local port = ''
    local options = ''
    sdomain, port, options = ksr_parse_sdomain(sdomain)
    local sdlen = string.len(sdomain);
    for idx, val in pairs(SUBDOMAIN_PASSTHROUGH) do
        local vallen = string.len(val);
        if sdlen > vallen and string.sub(sdomain, -vallen) == val then
            return true;
        end
    end
    return false;
end

-- match source ip against ALLOWADDR list
function ksr_is_src_trusted()
    local srcaddr = KSR.kx.get_srcip();
    for idx, val in pairs(ALLOWADDR) do
        if KSR.ipops.ip_is_in_subnet(srcaddr, val) > 0 then
            return true;
        end
    end
    return false;
end

-- match source ip against REJECT_600_IPS list
function ksr_is_src_reject_600_carrier()
    local srcaddr = KSR.kx.get_srcip();
    for idx, val in pairs(REJECT_600_IPS) do
        if KSR.ipops.ip_is_in_subnet(srcaddr, val) > 0 then
            return true;
        end
    end
    return false;
end

-- match source ip against FSADDR list
function ksr_is_src_fsaddr()
    local srcaddr = KSR.kx.get_srcip();
    for idx, val in pairs(FSADDR) do
        if KSR.ipops.ip_is_in_subnet(srcaddr, val) > 0 then
            return true;
        end
    end
    return false;
end

function ksr_check_array_for_domain_match(domain_array)
    local turi_domain = KSR.kx.gete_thost();
    local furi_domain = KSR.kx.gete_fhost();
    local ruri_domain = KSR.kx.gete_rhost();
    for idx, val in pairs(domain_array) do
        if string.find(turi_domain,"^" .. val) or string.find(furi_domain,"^" .. val) or string.find(ruri_domain,"^" .. val) then
            return true 
        end
    end
end

-- skip antiflood protection on SKIP_ANTIFLOOD_DOMAINS, SKIP_ANTIFLOOD_IPS, ALLOWADDR, and FSADDR lists
function ksr_skip_antiflood_for_transaction()
    if KSR.isflagset(FLT_GOT_AUTH_XKEYS) or ksr_check_array_for_domain_match(SKIP_ANTIFLOOD_DOMAINS) or ksr_is_src_trusted() or ksr_is_src_fsaddr() or ksr_is_skip_antiflood_ip() then
        return true 
    else
        return false
    end
end

function ksr_is_skip_antiflood_ip()
    local srcaddr = KSR.kx.get_srcip();
    for idx, val in pairs(SKIP_ANTIFLOOD_IPS) do
        if KSR.ipops.ip_is_in_subnet(srcaddr, val) > 0 then
            return true;
        end
    end
    return false;
end


-- SIP request routing
-- equivalent of request_route{}
function ksr_request_route()

    -- do not connect on tcp/tls to send reply
    KSR.set_reply_no_connect();

    -- from nodes with auth xkeys support
    if KSR.hdr.is_present("X-SignalWire-OutboundAuthToken") > 0
            and KSR.hdr.is_present("X-SignalWire-OutboundAuthTime") > 0 then
        local timehdr = KSR.hdr.gete("X-SignalWire-OutboundAuthTime");
        local tlimit = tonumber(timehdr);
        if (tlimit ~= nil) and (tlimit + AUTH_XKEYS_TIMEFRAME >= os.time()) then
            if KSR.auth_xkeys.auth_xkeys_check("X-SignalWire-OutboundAuthToken", "swk", "sha256",
                    timehdr .. ":" .. KSR.kx.get_method() .. ":" .. KSR.kx.get_callid() .. ":" .. KSR.kx.gete_fuser() .. ":" .. KSR.kx.gete_ruser()) > 0 then
                KSR.setflag(FLT_GOT_AUTH_XKEYS); -- got request that has valid auth xkeys signature
            end
        end
    end

    -- remove headers that should not be propagated
    KSR.hdr.remove("X-SignalWire-OutboundAuthTime");
    KSR.hdr.remove("X-SignalWire-OutboundAuthToken");
    KSR.hdr.remove("X-CID");
    KSR.hdr.remove("X-FS-Support");
	
    -- per request initial checks
    ksr_route_reqinit();

    -- filter unsupported requests
    if KSR.is_SUBSCRIBE() then
        KSR.sl.send_reply(405, "Method Not Allowed");
        KSR.x.exit();
    end

    -- NAT detection
    ksr_route_natdetect();

    -- CANCEL processing
    if KSR.is_CANCEL() then
        if KSR.tm.t_check_trans()>0 then
            ksr_route_relay();
        end
        return 1;
    end

    -- handle retransmissions
    if not KSR.is_ACK() then
        if KSR.tmx.t_precheck_trans()>0 then
            KSR.tm.t_check_trans();
            return 1;
        end
        if KSR.tm.t_check_trans()==0 then
            return 1;
        end
    end

    -- handle requests within SIP dialogs
    ksr_route_withindlg();

    -- -- only initial requests (no To tag)

    -- authentication
    ksr_route_auth();

    -- registrations
    ksr_route_registrar();

    -- record routing for dialog forming requests (in case they are routed)
    -- - remove preloaded route headers
    KSR.hdr.remove("Route");
    if KSR.is_method_in("IS") then
        KSR.rr.record_route();
    end

    -- account only INVITEs
    if KSR.is_INVITE() then
        KSR.setflag(FLT_ACC); -- do accounting

        if KSR.corex.has_ruri_user() < 0 then
            -- request with no Username in RURI - log and continue
            KSR.info("INVITE received with no Username in RURI.\n");
        end
    end

    -- routing inbound and outbound
    if ksr_is_src_fsaddr()
            or KSR.isflagset(FLT_GOT_AUTH_XKEYS)
            or KSR.dispatcher.ds_is_from_list_mode(100, 3) > 0 then
            -- or KSR.permissions.allow_source_address(100) > 0 then
        ksr_route_swoutbound();
        ksr_route_location();
        if KSR.is_myself_ruri() then
            KSR.sl.send_reply(404, "Local route");
            KSR.x.exit();
        end
        ksr_route_dlguri();
        ksr_route_relay();
    elseif KSR.dispatcher.ds_is_from_list_mode(200, 3) > 0 then
        ksr_route_swoutbound();
        ksr_route_location();
        if KSR.is_myself_ruri() then
            KSR.sl.send_reply(404, "Local route");
            KSR.x.exit();
        end
        ksr_route_dlguri();
        ksr_route_relay();
    else
        KSR.hdr.remove("P-SRC-IP");
        KSR.hdr.append("P-SRC-IP: " .. KSR.kx.get_srcip() .. "\r\n");
        ksr_dispatch();
    end

    return 1;
end

-- wrapper around tm relay function
function ksr_route_relay()
    -- enable additional event routes for forwarded requests
    -- - serial forking, RTP relaying handling, a.s.o.
    if KSR.is_method_in("IBSU") or KSR.is_UPDATE() then
        if KSR.tm.t_is_set("branch_route")<0 then
            KSR.tm.t_on_branch("ksr_branch_manage");
        end
    end
    if KSR.is_method_in("ISU") or KSR.is_UPDATE() then
        if KSR.tm.t_is_set("onreply_route")<0 then
            KSR.tm.t_on_reply("ksr_onreply_manage");
        end
    end

    if KSR.is_INVITE() then
        if KSR.tm.t_is_set("failure_route")<0 then
            KSR.tm.t_on_failure("ksr_failure_manage");
        end
    end

	if KSR.siputils.has_totag()<0 then
		KSR.info("===== outgoing request (initial)\n");
	else
		KSR.info("===== outgoing request (dialog)\n");
	end
    if KSR.is_INVITE() and KSR.siputils.has_totag()<0 then
        -- send reply from script if all outbound branches are dropped
        KSR.tm.t_set_disable_internal_reply(1);
        if KSR.tm.t_relay()<0 then
            if KSR.isflagset(FLT_BRANCHDROP) then
                KSR.tm.t_reply(404, "Target not found");
            else
                KSR.sl.sl_reply_error();
            end
        end
    else
        if KSR.tm.t_relay()<0 then
            KSR.sl.sl_reply_error();
        end
    end
    KSR.x.exit();
end


-- Per SIP request initial checks
function ksr_route_reqinit()

    local vsrcip =  KSR.kx.get_srcip();
    if WITH_ANTIFLOOD and not ksr_skip_antiflood_for_transaction() then
        if not KSR.is_myself_suri() then
            if KSR.htable.sht_is_null("ipban", vsrcip) < 0 then
                -- ip is already blocked
                KSR.info("request from blocked IP - " .. KSR.kx.get_method()
                        .. " from " .. KSR.kx.get_furi() .. " and to " .. KSR.kx.get_turi() .. " (IP:"
                        .. vsrcip .. ":" .. KSR.kx.get_srcport() .. ")\n");
                KSR.x.exit();
            end
            if KSR.pike.pike_check_req()<0 then
                KSR.err("ALERT: pike blocking " .. KSR.kx.get_method()
                        .. " from " .. KSR.kx.get_furi() .. " and to " .. KSR.kx.get_turi() .. " (IP:"
                        .. vsrcip .. ":" .. KSR.kx.get_srcport() .. ")\n");
                KSR.htable.sht_seti("ipban", vsrcip, 1);
                KSR.x.exit();
            end
        end
    end
    if KSR.corex.has_user_agent() then
        local uastr = string.lower(KSR.kx.gete_ua());
        for idx, val in pairs(BAD_USER_AGENTS) do
            if string.match(uastr, string.lower(val)) then
                KSR.sl.sl_send_reply(200, "OK");
                KSR.err("SPAM ALERT: pike blocking " .. KSR.kx.get_method()
                        .. " from " .. KSR.kx.get_furi() .. " (IP:"
                        .. vsrcip .. ":" .. KSR.kx.get_srcport() .. ") for having "
                        .. "a bad user agent (".. val ..")\n");
                KSR.htable.sht_seti("ipban", vsrcip, 1);
                KSR.x.exit();
            end
        end
    end

    if KSR.maxfwd.process_maxfwd(10) < 0 then
        KSR.sl.sl_send_reply(483,"Too Many Hops");
        KSR.x.exit();
    end

    if KSR.is_OPTIONS() then
        KSR.sl.sl_send_reply(200,"Keepalive");
        KSR.x.exit();
    end

    if KSR.sanity.sanity_check(1511, 7) < 0 then
        KSR.err("Malformed SIP message from "
                .. vsrcip .. ":" .. KSR.kx.get_srcport() .."\n");
        KSR.x.exit();
    end

end


-- Handle requests within SIP dialogs
function ksr_route_withindlg()
    if KSR.siputils.has_totag()<0 then return 1; end

    -- sequential request withing a dialog should
    -- take the path determined by record-routing
    if KSR.rr.loose_route()>0 then
        ksr_route_dlguri();
        if KSR.is_BYE() then
            KSR.setflag(FLT_ACC); -- do accounting ...
            KSR.setflag(FLT_ACCFAILED); -- ... even if the transaction fails
        elseif KSR.is_ACK() then
            -- ACK is forwarded statelessly
            ksr_route_natmanage();
        elseif KSR.is_NOTIFY() then
            -- Add Record-Route for in-dialog NOTIFY as per RFC 6665.
            KSR.rr.record_route();
        end
        ksr_route_relay();
        KSR.x.exit();
    end
    if KSR.is_ACK() then
        if KSR.tm.t_check_trans() > 0 then
            -- no loose-route, but stateful ACK;
            -- must be an ACK after a 487
            -- or e.g. 404 from upstream server
            ksr_route_relay();
            KSR.x.exit();
        else
            -- ACK without matching transaction ... ignore and discard
            KSR.x.exit();
        end
    end
    KSR.sl.sl_send_reply(404, "Not here");
    KSR.x.exit();
end

-- IP authorization and user uthentication
function ksr_route_auth()
    g_crt_projectid = "";

    -- skip auth for traffic from media servers
    if ksr_is_src_fsaddr()
            or KSR.isflagset(FLT_GOT_AUTH_XKEYS)
            or KSR.dispatcher.ds_is_from_list_mode(100, 3) > 0 then
        -- or KSR.permissions.allow_source_address(100) > 0 then
        return 1;
    elseif KSR.dispatcher.ds_is_from_list_mode(200, 3) > 0 then
        return 1;
    end

    -- from trusted list of addresses
    if ksr_is_src_trusted() then
        return 1;
    end

    local uafd = KSR.kx.gete_fhost();

    -- skip authentication for pass through subdomains
    if KSR.is_INVITE() then
        if ksr_domain_pass_thorugh(KSR.kx.gete_rhost()) then
            return 1;
        end
    end

    -- auth only a set of domains
    if DOMAINAUTH[uafd] == nil and not string.find(uafd, 'sip.eu-signalwire.com', 1, true) then
        KSR.info("404 Domain unavailable for host " .. KSR.kx.gete_fhost() .. " and user " .. KSR.kx.gete_fuser() .. "\n");
        KSR.sl.sl_send_reply(404, "Domain unavailable");
        KSR.x.exit();
    end

    -- challenge if no Auth header
    if KSR.is_REGISTER() then
        if KSR.hdr.is_present("Authorization") < 0 then
            KSR.auth.auth_challenge(uafd, 0);
            KSR.x.exit();
        end
    elseif KSR.hdr.is_present("Proxy-Authorization") < 0 then
        KSR.auth.auth_challenge(uafd, 0);
        KSR.x.exit();
    end

    local uapasswd = "";
    local aor = KSR.kx.gete_fuser() .. "@" .. KSR.kx.gete_fhost();

    if WITH_AUTHCACHE then
        uapasswd = KSR.htable.sht_gete("auth", aor);
        g_crt_projectid = KSR.htable.sht_gete("project", aor);
    end

    local hbody = "";
    if uapasswd == nil or string.len(uapasswd) < 8 then
        local srcaddr = KSR.kx.get_srcip();
        local xsp = "";
        if PROJECTIPID[srcaddr] ~= nil then
            if KSR.is_REGISTER() then
                xsp = PROJECTIPID[srcaddr];
            else
                KSR.sl.sl_send_reply(403, "Method restricted");
                KSR.x.exit();
            end
        end
        if string.len(xsp) < 4 then
            if KSR.hdr.is_present("Contact") > 0
                    and KSR.textops.search_hf("Contact", "x.signalwire.project", "f") > 0 then
                xsp = KSR.pv.gete("$(ct{tobody.params}{param.value,x.signalwire.project})");
            end
        end
        if string.len(xsp) < 4 then
            if string.match(KSR.kx.get_furi(), "counterpath") then
                xsp = "219c4f54-fa22-46b4-8c95-60edaf6cd1f8"
            end

            hbody = "{ \"username\": \"" .. KSR.kx.get_furi()
                .. "\", \"domain\": \"" .. uafd
                .. "\", \"project\": \"" .. xsp
                .. "\"}";
        else
            if string.sub(xsp, 1, 1) == "\"" and string.sub(xsp, -1, -1) == "\"" then
                -- value is already quoted
                hbody = "{ \"username\": \"" .. KSR.kx.get_furi()
                    .. "\", \"domain\": \"" .. uafd
                    .. "\", \"project\": \"" .. xsp
                    .. "\"}";
            else
                hbody = "{ \"username\": \"" .. KSR.kx.get_furi()
                    .. "\", \"domain\": \"" .. uafd
                    .. "\", \"project\": \"" .. xsp
                    .. "\"}";
            end
        end
        KSR.pvx.var_sets("hres", "");
        local hrcode = 0;
        local htries = 3; -- number of retries for http query
        local hres = "";
        repeat
            htries = htries - 1;
            hrcode = KSR.ruxc.http_post(AUTHURL, hbody, auth_http_headers, var_hres);
            hres = KSR.pvx.var_get("hres");
            if hrcode ~= 500 then
                if string.len(hres) < 10 then
                    -- no proper result -- try again
                    hrcode = 500;
                end
            end
        until (hrcode ~= 500 or htries > 0);

        KSR.info("Authorization HTTP query returned: " .. hres .. "\n");
        if string.len(hres) < 10 then
            -- no proper result -- challenge again for authentication
            KSR.info("401/407 Unauthorized: HTTP Authorization error - " .. hres .." - on " .. KSR.kx.gete_fuser() .. "@" .. uafd .. " with project: " .. xsp .. "\n");
            KSR.auth.auth_challenge(uafd, 0);
            KSR.x.exit();
        end
        local jsres = cjson.decode(hres);
        g_crt_projectid = jsres["project_id"];
        if jsres["ha1"] == nil or string.len(jsres["ha1"]) < 10 then
            KSR.info("500 Profile unavailable: jsres error - " .. jsres["ha1"] .." - on " .. KSR.kx.gete_fuser() .. "@" .. uafd .. "with project: " .. xsp .. "\n");
            KSR.sl.sl_send_reply(500, "Authentication unavailable");
            KSR.x.exit();
        end
        uapasswd = jsres["ha1"];
        if WITH_AUTHCACHE then
            KSR.htable.sht_sets("auth", aor, uapasswd);
            KSR.htable.sht_sets("project", aor, g_crt_projectid);
        end
    end

    if KSR.auth.pv_auth_check(uafd, uapasswd, 1, 1) < 0 then
        KSR.auth.auth_challenge(uafd, 0);
        KSR.x.exit();
    end

    KSR.auth.consume_credentials();
    return 1;
end

-- Caller NAT detection
function ksr_route_natdetect()
    KSR.force_rport();
    if KSR.nathelper.nat_uac_test(83)>0 then
        if KSR.is_REGISTER() then
            KSR.nathelper.fix_nated_register();
        elseif KSR.siputils.is_first_hop()>0 then
            KSR.nathelper.set_contact_alias();
        end
        KSR.setflag(FLT_NATS);
    end
    return 1;
end

-- NAT management and RTPProxy control
function ksr_route_natmanage()
    if KSR.siputils.is_request()>0 then
        if KSR.siputils.has_totag()>0 then
            if KSR.rr.check_route_param("nat=yes")>0 then
                KSR.setbflag(FLB_NATB);
            end
        end
    end
    if (not (KSR.isflagset(FLT_NATS) or KSR.isbflagset(FLB_NATB))) then
        return 1;
    end

    if KSR.isbflagset(FLB_NATB) then
        if KSR.siputils.has_totag()<0 then
            -- initial request with target behind nat
            -- do not connect on tcp/tls to send out if connection does not exist
            KSR.set_forward_no_connect();
        end
    end

    if KSR.siputils.is_request()>0 then
        if KSR.siputils.has_totag()<0 then
            if KSR.tmx.t_is_branch_route()>0 then
                KSR.rr.add_rr_param(";nat=yes");
            end
        end
    end
    if KSR.siputils.is_reply()>0 then
        if KSR.isbflagset(FLB_NATB) or KSR.nathelper.nat_uac_test(64)>0 then
            KSR.nathelper.set_contact_alias();
        end
    end
    return 1;
end

-- URI update for dialog requests
function ksr_route_dlguri()
    if not KSR.isdsturiset() then
        KSR.nathelper.handle_ruri_alias();
        if KSR.isdsturiset() then
            -- alias parameter was used - target behind nat
            -- do not connect on tcp/tls to send out if connection does not exist
            if ksr_is_src_fsaddr() or KSR.isflagset(FLT_GOT_AUTH_XKEYS) then
                KSR.set_forward_no_connect();
            end
        end
    end
    return 1;
end

-- Handle SIP registrations
function ksr_route_registrar()
    if not KSR.is_REGISTER() then return 1; end
    if KSR.isflagset(FLT_NATS) then
        KSR.setbflag(FLB_NATB);
        -- do SIP NAT pinging
        KSR.setbflag(FLB_NATSIPPING);
    end
    if KSR.is_WSS() then
        KSR.setbflag(FLB_WEBRTC);
    else
        KSR.setbflag(FLB_CLASSIC);
    end

    local touri = KSR.kx.get_turi();
    if WITH_BLADENOTIFY then
        local touser = KSR.kx.getw_tuser();
        local todomain = KSR.kx.getw_thost();
        -- local address = localip:localport
        local localaddr = KSR.kx.get_rcvadvip() .. ":5061";
        local evdata = "";
        local requested_media_webrtc = "false";
        local inodeid = "";

        KSR.cfgutils.lock(touri);

        -- If the inbound protocol is WSS, assume we need webrtc media
        if KSR.is_WSS() then
            requested_media_webrtc = "true";
        end

        evdata = "{ \"type\": \"sip\", \"domain\": \"" .. todomain .. "\", \"host\": \"" .. localaddr .. "\", \"requested_media_webrtc\": \"" .. requested_media_webrtc .. "\"";

        inodeid = REGISTRAR_NODEID;
        if string.len(inodeid) > 0 then
            evdata = evdata .. ", \"node_id\": \"" .. inodeid .. "\"";
        end

        evdata = evdata .. " }";

        local uri = build_registrar_uri(g_crt_projectid, touser)
        KSR.info("ksr_route_registrar: Sending Registration HTTP query: POST " .. uri .. " " .. evdata .. "\n");
        local hrcode = 0;
        hrcode = KSR.ruxc.http_post(uri, evdata, registrar_http_headers, var_hres);
        local hres = KSR.pvx.var_get("hres");
        KSR.info("ksr_route_registrar: Registration HTTP query returned: " .. hrcode .. " " .. hres .. "\n");

        if hrcode > 299 then
            KSR.cfgutils.unlock(touri);
            KSR.warn("Failed register - " .. uri .. " " .. evdata .. "\n");
            KSR.sl.send_reply(500, "Cluster registration failure");
            KSR.x.exit();
        end
        local conid = KSR.kx.get_conid();
        if conid >= 0 then
            KSR.htable.sht_sets("tcpid", "c" .. conid, "call-id: " .. KSR.kx.get_callid() .. " user: " .. touri);
        end
        if KSR.registrar.save("location", 0)<0 then
            KSR.sl.sl_reply_error();
        end
        if KSR.registrar.registered_uri("location", touri) < 0 then
            -- UA has no valid registration record - it was unregister - push it as a new event
            if string.len(inodeid) > 0 then
                uri = uri .. "/" .. encode_uri_component(inodeid) .. "/null"
                KSR.info("ksr_route_registrar: Sending Unregistration HTTP query: DELETE " .. uri .. "\n");
                hrcode = KSR.ruxc.http_delete(uri, "", registrar_http_headers, var_hres);
                local hres = KSR.pvx.var_get("hres");
                KSR.info("ksr_route_registrar: Unregistration HTTP query returned: " .. hrcode .. " " .. hres .. "\n");
                if hrcode > 299 then
                    KSR.warn("Failed unregister - " .. uri .. " " .. evdata .. "\n");
                end
            end
            -- sending unregister in non-blocking mode via mqueue + rtimer
            -- KSR.mqueue.mq_add("mqregister", evcmd, evdata);
        end
        KSR.cfgutils.unlock(touri);
        KSR.x.exit();
    else
        -- else for WITH_BLADENOTIFY - just do the usual save of registration
        local conid = KSR.kx.get_conid();
        if conid >= 0 then
            KSR.htable.sht_sets("tcpid", "c" .. conid, "call-id: " .. KSR.kx.get_callid() .. " user: " .. touri);
        end
        if KSR.registrar.save("location", 0)<0 then
            KSR.sl.sl_reply_error();
            KSR.x.exit();
        end
    end
    KSR.x.exit();
end

-- User location service
function ksr_route_location()
    -- only for a set of domains
    local uard = KSR.kx.gete_rhost();
    if DOMAINAUTH[uard] == nil and not string.find(uard, 'sip.eu-signalwire.com', 1, true) then
        KSR.info("======> UARD: " .. uard .. "\n");
        return 1;
    end

    local rc = KSR.registrar.lookup("location");
    if rc<0 then
        KSR.tm.t_newtran();
        if rc==-2 then
            KSR.sl.send_reply(405, "Method Not Allowed");
        else
            KSR.sl.send_reply(404, "Not Found");
        end
        KSR.x.exit();
    end

    -- do not connect on tcp/tls to forward request if contact connection does not exist
    KSR.set_forward_no_connect();

    ksr_route_relay();
    KSR.x.exit();
end


-- Outbound to external SIP providers
function ksr_route_swoutbound()
	if KSR.hdr.is_present("X-SignalWire-Outbound") < 0 then
		return 1;
	end
	KSR.hdr.remove("X-SignalWire-Outbound");
	local obproxy = KSR.hdr.gete("X-SignalWire-Outbound-Proxy");
	if string.len(obproxy) > 4 then
		KSR.setdsturi(obproxy);
		KSR.hdr.remove("X-SignalWire-Outbound-Proxy");
    else
        local prouteto = KSR.hdr.gete("P-Route-To");
        if string.len(prouteto) > 4 then
            KSR.pvx.xavp_slist_explode(prouteto, ",", "t", "prouteto");
            KSR.tm.t_on_failure("ksr_failure_prouteto");
            KSR.tm.t_set_fr(120000, 4000);
            KSR.hdr.remove("P-Route-To");
            KSR.setflag(FLT_PROUTETO);
        end
	end
	ksr_route_relay();
	KSR.x.exit();
end

-- Manage outgoing branches
-- equivalent of branch_route[...]{}
function ksr_branch_manage()
    KSR.info("new branch [".. KSR.pv.gete("$T_branch_idx")
                .. "] to ".. KSR.kx.get_ruri() .. "\n");
    if KSR.is_INVITE() and KSR.siputils.has_totag()<0 then
        local ttype = KSR.hdr.gete("X-Target-Type");
        if ttype == "classic" then
            if not KSR.isbflagset(FLB_CLASSIC) then
                KSR.setflag(FLT_BRANCHDROP);
                KSR.x.drop();
            end
        elseif ttype == "webrtc" then
            if not KSR.isbflagset(FLB_WEBRTC) then
                KSR.setflag(FLT_BRANCHDROP);
                KSR.x.drop();
            end
        end
    end
    KSR.hdr.remove("X-Target-Type");

    ksr_route_natmanage();

    if KSR.isflagset(FLT_AUTH_XKEYS) then
        local timehdr = tostring(os.time());
        KSR.hdr.append("X-SignalWire-OutboundAuthTime: " .. timehdr .. "\r\n");
        KSR.auth_xkeys.auth_xkeys_add("X-SignalWire-OutboundAuthToken", "swk", "sha256",
                timehdr .. ":" .. KSR.kx.get_method() .. ":" .. KSR.kx.get_callid() .. ":" .. KSR.kx.gete_fuser() .. ":" .. KSR.kx.gete_ruser());
    end

    if KSR.isflagset(FLT_PROUTETO) then
        if KSR.kx.get_ruri() ~= KSR.kx.get_turi() then
            if KSR.pv.is_null("$tn") then
                KSR.uac.uac_replace_to_uri(KSR.kx.get_ruri());
            else
                KSR.uac.uac_replace_to("\"" .. KSR.kx.gete_ruser() .. "\"", KSR.kx.get_ruri());
            end
        end
    end

    return 1;
end

-- Manage incoming replies
-- equivalent of onreply_route[...]{}
function ksr_onreply_manage()
    KSR.info("===== incoming response (tm)\n");
    local scode = KSR.kx.get_status() or 0;
    if scode>100 and scode<299 then
        ksr_route_natmanage();
    end
    return 1;
end

-- Manage failure routing cases
-- equivalent of failure_route[...]{}
function ksr_failure_manage()
    ksr_route_natmanage();

    if KSR.tm.t_is_canceled()>0 then
        return 1;
    end
    return 1;
end

-- SIP response handling
-- equivalent of reply_route{}
function ksr_reply_route()
    KSR.info("===== incoming response (core)\n");
    return 1;
end

-- Dispatch requests
function ksr_dispatch()
    local dsgrp = 100;
    KSR.tm.t_set_fr(120000, 2000);
    if WITH_REDISROUTE then
        -- get routing info from redis
        KSR.ndb_redis.redis_free("r1");
        KSR.ndb_redis.redis_cmd_p1("srv1", "GET %s", "routeto:" .. KSR.kx.gete_fuser() .. "@".. KSR.kx.gete_fhost(), "r1");
        local r1type = KSR.pv.get("$redis(r1=>type)");
        if r1type == KSR.pv.get("$redisd(rpl_int)") then
            dsgrp = KSR.pv.get("$redis(r1=>value)");
        elseif r1type == KSR.pv.get("$redisd(rpl_str)") then
            local r1val = KSR.pv.get("$redis(r1=>value)");
            local r1num = tonumber(r1val);
            if r1num == nil then
                if string.len(r1val) > 4 then
                    -- direct routing by address
                    KSR.setdsturi(r1val);
                    KSR.ndb_redis.redis_free("r1");
                    ksr_route_relay();
                    KSR.x.exit();
                end
            else
                dsgrp = r1num;
            end
        end
        KSR.ndb_redis.redis_free("r1");
    end

    dsgrp = ksr_choose_dispatcher_group();

    -- weight-based (9) dispatching on group 'dsgrp' (default 100)
    if KSR.dispatcher.ds_select_dst(dsgrp, 4) < 0 then
        KSR.sl.send_reply(404, "No destination");
        KSR.x.exit();
    end

    KSR.setflag(FLT_AUTH_XKEYS);
    KSR.info("--- SCRIPT: going to <" .. KSR.kx.gete_ruser() .. "> via <"
            .. KSR.kx.gete_duri() .. ">\n");
    KSR.tm.t_on_failure("ksr_failure_dispatch");
    ksr_route_relay();
    KSR.x.exit();
end

-- Try next destionations in failure route
function ksr_failure_dispatch()
	if KSR.tm.t_is_canceled() > 0 then
		return 1;
    end

    if KSR.is_INVITE() then
        KSR.info("--- SCRIPT: INVITE failure routing - ruri: " .. KSR.kx.get_ruri()
                .. " - code:" .. KSR.pv.gete("$T_reply_code") .. "\n");
    end

    if KSR.tm.t_check_status("403|404|48[0-9]|502|6[0-9][0-9]") > 0 then

        -- Carrier-Specific Failures
        if ksr_is_src_reject_600_carrier() then
            -- ========= Bandwidth and friends =========
            -- Generate a 600, which is universally most likely to reject the call
            KSR.sl.send_reply(600, "Busy Everywhere");
            KSR.x.exit();
        elseif string.match(KSR.pv.gete("$ct"), "flowroute.com") or string.match(KSR.kx.gete_fhost(), "fl.gg") then
            --  ======== Flowroute ========
            -- Flowroute upstreams don't respect 603, and will constantly retry on many other codes
            -- They require a 180/183 (use 183 w/o SDP to prevent ringing)
            -- Generate a 600, which is universally most likely to reject the call
            -- Note: Flowroute should fix this on their side. We'll handle it for now.
            KSR.sl.send_reply(183, "Session Progress");
            KSR.sl.send_reply(600, "Busy Everywhere");
            KSR.x.exit();
        end

        -- Return original reply if unmatched
        return 1;
    end

	-- next DST - only for the rest of 4xx, 5xx and 6xx
	if KSR.tm.t_check_status("[4-6][0-9][0-9]") > 0 then
		if KSR.dispatcher.ds_next_dst() > 0 then
            if KSR.is_INVITE() then
                KSR.info("--- SCRIPT: INVITE failure routing - new duri: " .. KSR.kx.gete_duri()
                        .. " - ruri:" .. KSR.kx.get_ruri() .. "\n");
            end
			KSR.tm.t_on_failure("ksr_failure_dispatch");
			ksr_route_relay();
			KSR.x.exit();
		else
            KSR.info("--- SCRIPT: INVITE failure routing - no new duri - ruri: "
                        .. KSR.kx.get_ruri() .. "\n");
        end
	end
end

-- Try next destionations for outbound routing using P-Route-To
function ksr_failure_prouteto()
    if KSR.tm.t_is_canceled() > 0 then
        return 1;
    end
    local rplcode = KSR.tm.t_get_status_code();
    if rplcode==486 or rplcode==487 or rplcode>=600 then
        -- no re-routing for these reply codes
        return 1;
    end

    local nexturi = KSR.pvx.xavp_child_gete("prouteto", "v");
    if string.len(nexturi) > 4 then
        KSR.seturi(nexturi);
        KSR.pvx.xavp_child_rm("prouteto", "v");
        KSR.tm.t_on_failure("ksr_failure_prouteto");
        KSR.tm.t_set_fr(120000, 4000);
        ksr_route_relay();
        KSR.x.exit();
    end
end

-- RTimer callback to retrieve message from mqueue and push to blade network
function ksr_rtimer(evname)
    while KSR.mqueue.mq_fetch("mqregister") > 0 do
        local method = KSR.pv.gete("$mqk(mqregister)");
        local uri = KSR.pv.gete("$mqv(mqregister)");
        if method == "delete" and string.len(uri) > 0 then
            local hrcode = 0;
            KSR.info("ksr_rtimer: Sending Unregistration HTTP query: DELETE " .. uri .. "\n");
            hrcode = KSR.ruxc.http_delete(uri, "", registrar_http_headers, var_hres);
            local hres = KSR.pvx.var_get("hres");
            KSR.info("Unregistration HTTP query returned: " .. hrcode .. " " .. hres .. "\n");
            if hrcode > 299 then
              KSR.warn("Failed unregister: " .. uri .. " - " .. evdata .. "\n");
            end
        end
    end
end

-- xhttp request callback
function ksr_xhttp_request(evname)
	KSR.set_reply_no_connect();
	KSR.dbg("HTTP Request Received\n");

	local hupgrade = KSR.hdr.gete("Upgrade");
	local hconnection = KSR.hdr.gete("Connection");

	if KSR.is_method_in("G") and string.match(hupgrade, "websocket")
			and string.match(hconnection, "Upgrade") then
        local hhost = KSR.hdr.gete("Host");
		if string.len(hhost) <= 0 or not KSR.is_myself("sip:" .. hhost) then
			KSR.info("Bad host: " .. hhost .. "\n");
			KSR.xhttp.xhttp_reply(403, "Forbidden", "", "");
			KSR.x.exit();
		end
		local lret = KSR.websocket.handle_handshake();
		if lret > 0 then
			KSR.info("Websocket handshake successful\n");
			KSR.x.exit();
		end
		if lret == 0 then
			KSR.info("Websocket handshake failed\n");
			KSR.x.exit();
		end
    end
    KSR.info("404 - Rejecting websocket with invalid HTTP Method:" .. KSR.kx.get_method() .. ", Upgrade: " .. hupgrade .. ", Connection: " .. hconnection .."\n");
	KSR.xhttp.xhttp_reply(404, "Not found", "", "");
end

function ksr_unregister_event(evname)
    local aor = KSR.pv.getw("$ulc(exp=>aor)");
    local g_crt_projectid = KSR.htable.sht_gete("project", aor);
    local inodeid = REGISTRAR_NODEID;

    if KSR.registrar.registered_uri("location", "sip:" .. aor) > 0 then
        -- user still has valid contacts on the this node - don't remove all entries from registrar
        return;
    end

    user, domain = string.match(aor, "(.*)%@(.*)")
    local uri = build_registrar_uri(g_crt_projectid, user)
    uri = uri .. "/" .. encode_uri_component(inodeid) .. "/null"

    -- sending unregister in non-blocking mode via mqueue + rtimer
    if string.len(g_crt_projectid) > 0 then
        KSR.info( "Expired contact for " .. aor .. ", " .. uri .. " - Unregistering...\n");
        KSR.mqueue.mq_add("mqregister", "delete", uri);
    else
        KSR.info( "Expired contact for " .. aor .. " - Missing Project ID, ignoring...\n");
    end
end

-- event callback function for tcp connection close
function ksr_tcpops_event(evname)
    local conid = KSR.kx.get_conid();
    if conid > 0 and KSR.htable.sht_is_null("tcpid", "c" .. conid) < 0 then
        KSR.info("tcp connection closed - id: " .. conid .. " " .. KSR.htable.sht_gete("tcpid", "c" .. conid) .. "\n");
    end
end
-- sipdump callback to print recv/send traffic
function ksr_sipdump_event(evname)
	KSR.info("Source IP: " .. KSR.sipdump.get_src_ip() .. " - Tag: " .. KSR.sipdump.get_tag() .. "\n" .. KSR.sipdump.get_buf());
end

function ksr_choose_dispatcher_group()
    -- Quick redirect for specific test domain
    local fromuri = KSR.kx.get_furi();
    if string.match(fromuri, "softphone.com") or string.match(fromuri, "counterpath.com") or string.match(fromuri, "bria%-x") or string.match(fromuri, "mobilevoiplive.com") then
        return 200;
    -- Match any domains in the Stable Routing list to avoid the Canary instances
    elseif ksr_check_array_for_domain_match(STABLE_ROUTING_DOMAINS) then
        return 700;
    else
        return 100;
    end
end


-- event callback function on shutdown
function ksr_bladec_event_shutdown(evname)
    local evcmd = "purge";
    local inodeid = REGISTRAR_NODEID;
    local evdata = "{ \"node_id\": \"" .. inodeid .. "\" }";

    KSR.info("Sending direct blade.execute for shutdown: " .. evcmd .. " - " .. evdata .. "\n");
    if KSR.bladec.relay("", "registrar", evcmd, evdata) < 0 then
        KSR.warn("Failed sending direct blade.execute: " .. evcmd .. " - " .. evdata .. "\n");
    end
end

-- event callback function on dispatcher dst state change
function ksr_dispatcher_event(evname)
	KSR.info("event: " .. evname .. " - addr: " .. KSR.kx.get_ruri() .. "\n");
	return 1;
end
