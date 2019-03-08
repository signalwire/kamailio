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
WITH_BLADENOTIFY=true
WITH_REDISROUTE=false

-- global variables corresponding to defined values (e.g., flags) in kamailio.cfg
FLT_ACC=1
FLT_ACCMISSED=2
FLT_ACCFAILED=3
FLT_NATS=5

FLB_NATB=6
FLB_NATSIPPING=7

AUTHURL=os.getenv('KAMAILIO_AUTHORIZATION_URL')
-- AUTHURL="https://api.swire.io/api/provider_callback/kamailio/authorize"

-- Special domain authorization for CNAME'd domains
DOMAINAUTH= {}
DOMAINAUTH["sip.softphone.com"] = 1
DOMAINAUTH["sip.bria-x.org"] = 1
DOMAINAUTH["sip.bria-x.net"] = 1
DOMAINAUTH["sip.mobilevoiplive.com"] = 1

-- list of addresses to allow traffic from without user auth
-- must have subnet mask (CIDR notation - use /32 for single ip addr)
ALLOWADDR={
    "147.75.65.192/28",
    "34.226.36.32/28",
    "34.210.91.112/28",
    "147.75.60.160/28",
    "67.231.1.188/32",
    "67.231.4.138/32"
};

-- list of freeswitch addresses to allow traffic from without user auth
-- must have subnet mask (CIDR notation - use /32 for single ip addr)
FSADDR={
    "159.65.80.152/32",
    "178.128.235.231/32",
    "159.65.253.227/32",
    "167.99.42.191/32",
    "104.248.158.21/32",
    "104.248.75.157/32",
    "10.92.0.0/16"
};

-- list of ip addresses that have the project id mapped statically
PROJECTIPID = {}
PROJECTIPID["127.0.0.1"] = "signalwire.localhost"

local g_crt_projectid = ""

-- match source ip against ALLOWADDR list
function ksr_is_src_trusted()
    local srcaddr = KSR.pv.get("$si");
    for idx, val in pairs(ALLOWADDR) do
        if KSR.ipops.ip_is_in_subnet(srcaddr, val) > 0 then
            return true;
        end
    end
    return false;
end

-- match source ip against FSADDR list
function ksr_is_src_fsaddr()
    local srcaddr = KSR.pv.get("$si");
    for idx, val in pairs(FSADDR) do
        if KSR.ipops.ip_is_in_subnet(srcaddr, val) > 0 then
            return true;
        end
    end
    return false;
end

-- SIP request routing
-- equivalent of request_route{}
function ksr_request_route()

    -- per request initial checks
    ksr_route_reqinit();

    -- filter unsupported requests
    if KSR.is_SUBSCRIBE() then
        KSR.sl.send_reply(405, "Method Not Allowed");
        KSR.x.exit();
    end

    if KSR.is_NOTIFY() then
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
        KSR.hdr.append("P-SRC-IP: " .. KSR.pv.get("$si") .. "\r\n");
        ksr_dispatch();
    end

    return 1;
end

-- wrapper around tm relay function
function ksr_route_relay()
    -- enable additional event routes for forwarded requests
    -- - serial forking, RTP relaying handling, a.s.o.
    if KSR.is_method_in("IBSU") then
        if KSR.tm.t_is_set("branch_route")<0 then
            KSR.tm.t_on_branch("ksr_branch_manage");
        end
    end
    if KSR.is_method_in("ISU") then
        if KSR.tm.t_is_set("onreply_route")<0 then
            KSR.tm.t_on_reply("ksr_onreply_manage");
        end
    end

    if KSR.is_INVITE() then
        if KSR.tm.t_is_set("failure_route")<0 then
            KSR.tm.t_on_failure("ksr_failure_manage");
        end
    end

    if KSR.tm.t_relay()<0 then
        KSR.sl.sl_reply_error();
    end
    KSR.x.exit();
end


-- Per SIP request initial checks
function ksr_route_reqinit()
    if WITH_ANTIFLOOD then
        if not KSR.is_myself_suri() then
            if not KSR.pv.is_null("$sht(ipban=>$si)") then
                -- ip is already blocked
                KSR.info("request from blocked IP - " .. KSR.pv.get("$rm")
                        .. " from " .. KSR.pv.get("$fu") .. " (IP:"
                        .. KSR.pv.get("$si") .. ":" .. KSR.pv.get("$sp") .. ")\n");
                KSR.x.exit();
            end
            if KSR.pike.pike_check_req()<0 then
                KSR.err("ALERT: pike blocking " .. KSR.pv.get("$rm")
                        .. " from " .. KSR.pv.get("$fu") .. " (IP:"
                        .. KSR.pv.get("$si") .. ":" .. KSR.pv.get("$sp") .. ")\n");
                KSR.pv.seti("$sht(ipban=>$si)", 1);
                KSR.x.exit();
            end
        end
    end
    if KSR.corex.has_user_agent() then
        local uastr = KSR.pv.gete("$ua");
        if (string.find(uastr, "friendly-scanner")
                or string.find(uastr, "sipcli")) then
            KSR.sl.sl_send_reply(200, "OK");
            KSR.x.exit();
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
                .. KSR.pv.get("$si") .. ":" .. KSR.pv.get("$sp") .."\n");
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

    local uafd = KSR.pv.get("$fd");

    -- auth only a set of domains
    if DOMAINAUTH[uafd] == nil and not string.find(uafd, 'sip.signalwire.com') and not string.find(uafd, 'sip.swire.io') then
        KSR.info("500 Domain unavailable for " .. KSR.pv.get("$fu") .. "\n");
        KSR.sl.sl_send_reply(500, "Domain unavailable");
        KSR.x.exit();
    end

    -- challenge if no Auth header
    if KSR.is_REGISTER() then
        if KSR.hdr.is_present("Authorization") < 0 then
            KSR.auth.auth_challenge(KSR.pv.get("$fd"), 0);
            KSR.x.exit();
        end
    elseif KSR.hdr.is_present("Proxy-Authorization") < 0 then
        KSR.auth.auth_challenge(KSR.pv.get("$fd"), 0);
        KSR.x.exit();
    end

    local uapasswd = "";

    if WITH_AUTHCACHE then
        uapasswd = KSR.pv.gete("$sht(auth=>$fU@$fd)");
        g_crt_projectid = KSR.pv.gete("$sht(project=>$fU@$fd)");
    end

    local hbody = "";
    if uapasswd == nil or string.len(uapasswd) < 8 then
        local srcaddr = KSR.pv.get("$si");
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
            if string.match(KSR.pv.get("$fu"), "counterpath") then
                xsp = "219c4f54-fa22-46b4-8c95-60edaf6cd1f8"
            end

            hbody = "{ \"username\": \"" .. KSR.pv.get("$fu")
                .. "\", \"domain\": \"" .. KSR.pv.get("$fd")
                .. "\", \"project\": \"" .. xsp
                .. "\"}";
        else
            if string.sub(xsp, 1, 1) == "\"" and string.sub(xsp, -1, -1) == "\"" then
                -- value is already quoted
                hbody = "{ \"username\": \"" .. KSR.pv.get("$fu")
                    .. "\", \"domain\": \"" .. KSR.pv.get("$fd")
                    .. "\", \"project\": \"" .. xsp
                    .. "\"}";
            else
                hbody = "{ \"username\": \"" .. KSR.pv.get("$fu")
                    .. "\", \"domain\": \"" .. KSR.pv.get("$fd")
                    .. "\", \"project\": \"" .. xsp
                    .. "\"}";
            end
        end
        KSR.pv.sets("$var(hres)", "");
        KSR.http_client.query_post_hdrs(AUTHURL, hbody,
                "Content-Type: application/json", "$var(hres)");

        local hres = KSR.pv.gete("$var(hres)");
        KSR.info("Authorization HTTP query returned: " .. hres .. "\n");
        if string.len(hres) < 10 then
            -- no proper result -- try one more time the http api query
            KSR.pv.sets("$var(hres)", "");
            KSR.http_client.query_post_hdrs(AUTHURL, hbody,
                    "Content-Type: application/json", "$var(hres)");
            hres = KSR.pv.gete("$var(hres)");
            if string.len(hres) < 10 then
                KSR.info("500 Backend unavailable: HTTP Authorization error - " .. hres .." - on " .. KSR.pv.get("$fU") .. "@" .. KSR.pv.get("$fd") .. " with project: " .. xsp .. "\n");
                KSR.sl.sl_send_reply(500, "Backend unavailable");
                KSR.x.exit();
            end
        end
        local jsres = cjson.decode(hres);
        g_crt_projectid = jsres["project_id"];
        if jsres["ha1"] == nil or string.len(jsres["ha1"]) < 10 then
            KSR.info("500 Profile unavailable: jsres error - " .. jsres["ha1"] .." - on " .. KSR.pv.get("$fU") .. "@" .. KSR.pv.get("$fd") .. "with project: " .. xsp .. "\n");
            KSR.sl.sl_send_reply(500, "Profile unavailable");
            KSR.x.exit();
        end
        uapasswd = jsres["ha1"];
        if WITH_AUTHCACHE then
            KSR.pv.sets("$sht(auth=>$fU@$fd)", uapasswd);
            KSR.pv.sets("$sht(project=>$fU@$fd)", g_crt_projectid);
        end
    end

    if KSR.auth.pv_auth_check(uafd, uapasswd, 1, 1) < 0 then
        KSR.auth.auth_challenge(KSR.pv.get("$fd"), 0);
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
    if KSR.registrar.save("location", 0)<0 then
        KSR.sl.sl_reply_error();
        KSR.x.exit();
    end

    if WITH_BLADENOTIFY then
        local touri = KSR.pv.getw("$tu");
        local touser = KSR.pv.getw("$tU");
        local todomain = KSR.pv.getw("$td");
        -- local address = localip:localport
        local localaddr = KSR.pv.getw("$RAi") .. ":5061";
        local evcmd = "";
        local evdata = "";
        local requested_media_webrtc = "false";

        if KSR.registrar.registered_uri("location", touri) > 0 then
            -- UA has a valid registration record
            evcmd = "register";

            -- If the inbound protocol is WSS, assume we need webrtc media
            if KSR.pv.getw("$proto") == "wss" then
                requested_media_webrtc = "true";
            end

            evdata = "{ \"resource\": \"" .. touser .. "\", \"project\": \"" ..  g_crt_projectid ..  "\", \"type\": \"sip\", \"domain\": \""
                        .. todomain .. "\", \"host\": \"" .. localaddr .. "\", \"requested_media_webrtc\": \"" .. requested_media_webrtc .. "\" }";
        else
            -- UA has no valid registration record
            evcmd = "unregister";
            evdata = "{ \"resource\": \"" .. touser .. "\", \"project\": \"" .. g_crt_projectid .. "\", \"type\": \"sip\" }";
        end
        KSR.mqueue.mq_add("mqregister", evcmd, evdata);
    end
    KSR.x.exit();
end

-- User location service
function ksr_route_location()
    -- only for a set of domains
    local uard = KSR.pv.get("$rd");
    if DOMAINAUTH[uard] == nil and not string.find(uard, 'sip.signalwire.com') and not string.find(uard, 'sip.swire.io') then
        KSR.info("======> UARD: " .. uard .. "\n");
        return 1;
    end

    local rc = KSR.registrar.lookup("location");
    if rc<0 then
        KSR.tm.t_newtran();
        if rc==-2 then
            KSR.sl.send_reply("405", "Method Not Allowed");
        else
            KSR.sl.send_reply("404", "Not Found");
        end
        KSR.x.exit();
    end

    ksr_route_relay();
    KSR.x.exit();
end


-- Outbound to external SIP providers
function ksr_route_swoutbound()
	if KSR.hdr.is_present("X-SignalWire-Outbound") < 0 then
		return 1;
	end
	local obproxy = KSR.pv.gete("$hdr(X-SignalWire-Outbound-Proxy)");
	if string.len(obproxy) > 4 then
		KSR.setdsturi(obproxy);
		KSR.hdr.remove("X-SignalWire-Outbound-Proxy");
	end
	KSR.hdr.remove("X-SignalWire-Outbound");
	ksr_route_relay();
	KSR.x.exit();
end

-- Manage outgoing branches
-- equivalent of branch_route[...]{}
function ksr_branch_manage()
    KSR.info("new branch [".. KSR.pv.get("$T_branch_idx")
                .. "] to ".. KSR.pv.get("$ru") .. "\n");
    ksr_route_natmanage();
    return 1;
end

-- Manage incoming replies
-- equivalent of onreply_route[...]{}
function ksr_onreply_manage()
    KSR.info("incoming reply\n");
    local scode = KSR.pv.get("$rs");
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
    KSR.info("===== response - from kamailio lua script\n");
    return 1;
end

-- Dispatch requests
function ksr_dispatch()
    local dsgrp = 100;
    if WITH_REDISROUTE then
        -- get routing info from redis
        KSR.ndb_redis.redis_free("r1");
        KSR.ndb_redis.redis_cmd_p1("srv1", "GET %s", "routeto:" .. KSR.pv.get("$fU") .. "@".. KSR.pv.get("$fd"), "r1");
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

    -- Quick redirect for specific test domain
    if string.match(KSR.pv.get("$fu"), "softphone.com") or string.match(KSR.pv.get("$fu"), "counterpath.com") or string.match(KSR.pv.get("$fu"), "bria%-x") or string.match(KSR.pv.get("$fu"), "mobilevoiplive.com") then
        dsgrp = 200;
    end

    -- round robin (4) dispatching on group 'dsgrp' (default 100)
    if KSR.dispatcher.ds_select_dst(dsgrp, 4) < 0 then
        KSR.sl.send_reply(404, "No destination");
        KSR.x.exit();
    end

    KSR.info("--- SCRIPT: going to <" .. KSR.pv.get("$ru") .. "> via <"
            .. KSR.pv.get("$du") .. ">\n");
    KSR.tm.t_on_failure("ksr_failure_dispatch");
    ksr_route_relay();
    KSR.x.exit();
end

-- Try next destionations in failure route
function ksr_failure_dispatch()
	if KSR.tm.t_is_canceled() > 0 then
		return 1;
	end
	-- next DST - only for 4xx, 5xx and 6xx
	if KSR.tm.t_check_status("[4-6][0-9][0-9]") > 0 then
		if KSR.dispatcher.ds_next_dst() > 0 then
			KSR.tm.t_on_failure("ksr_failure_dispatch");
			ksr_route_relay();
			KSR.x.exit();
		end
	end
end

-- RTimer callback to retrieve message from mqueue and push to blade network
function ksr_rtimer_bladec(evname)
	while KSR.mqueue.mq_fetch("mqregister") > 0 do
		local bevcmd = KSR.pv.gete("$mqk(mqregister)");
		local bevdata = KSR.pv.gete("$mqv(mqregister)");
		if string.len(bevcmd) > 0 and string.len(bevdata) > 0 then
			KSR.info("Sending blade.execute: " .. bevcmd .. " - " .. bevdata .. "\n"); 
			KSR.bladec.relay("", "registrar", bevcmd, bevdata);
		end
	end
end

-- xhttp request callback
function ksr_xhttp_request(evname)
	KSR.set_reply_no_connect();
	KSR.dbg("HTTP Request Received\n");

	local hupgrade = KSR.pv.gete("$hdr(Upgrade)");
	local hconnection = KSR.pv.gete("$hdr(Connection)");

	if KSR.is_method_in("G") and string.match(hupgrade, "websocket")
			and string.match(hconnection, "Upgrade") then
		local hhost = KSR.pv.gete("$hdr(Host)");
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
    KSR.info("404 - Rejecting websocket with invalid HTTP Method:" .. KSR.pv.getw("$rm") .. ", Upgrade: " .. hupgrade .. ", Connection: " .. hconnection .."\n");
	KSR.xhttp.xhttp_reply("404", "Not found", "", "");
end
