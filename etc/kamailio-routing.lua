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
WITH_ANTIFLOOD=false
WITH_AUTHCACHE=false

-- global variables corresponding to defined values (e.g., flags) in kamailio.cfg
FLT_ACC=1
FLT_ACCMISSED=2
FLT_ACCFAILED=3
FLT_NATS=5

FLB_NATB=6
FLB_NATSIPPING=7

AUTHURL="https://api.signalwire.com/api/provider_callback/kamailio/authorize"

DOMAINAUTH= {}
DOMAINAUTH["counterpath.sip.signalwire.com"] = 1
DOMAINAUTH["evan.sip.signalwire.com"] = 1
DOMAINAUTH["bria.swire.io"] = 1
DOMAINAUTH["beta.bria-x.com"] = 1
DOMAINAUTH["1.bria-x.com"] = 1

-- list of addresses to allow traffic from without user auth
-- must have subnet mask (CIDR notation - use /32 for single ip addr)
ALLOWADDR={
	"147.75.65.192/28",
	"34.226.36.32/28",
	"34.210.91.112/28",
	"147.75.60.160/28"
};

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

-- SIP request routing
-- equivalent of request_route{}
function ksr_request_route()

	-- per request initial checks
	ksr_route_reqinit();

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
			-- request with no Username in RURI
			KSR.sl.sl_send_reply(484,"Address Incomplete");
			return 1;
		end
	end

	-- routing inbound and outbound
	if KSR.dispatcher.ds_is_from_list("100") > 0 then
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
				KSR.dbg("request from blocked IP - " .. KSR.pv.get("$rm")
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
		local uastr = KSR.pv.getw("$ua");
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

	if KSR.is_OPTIONS()
			and KSR.is_myself_ruri()
			and KSR.corex.has_ruri_user() < 0 then
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
	-- skip auth for traffic from media servers
	if KSR.dispatcher.ds_is_from_list("100") > 0 then
		return 1;
	end

	-- from trusted list of addresses
	if ksr_is_src_trusted() then
		return 1;
	end

	local uafd = KSR.pv.get("$fd");

	-- auth only a set of domains
	if DOMAINAUTH[uafd] == nil then
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
		uapasswd = KSR.pv.getw("$sht(auth=>$fU@$fd)");
	end

	local hbody = "";
	if uapasswd == nil or string.len(uapasswd) < 10 then
		if KSR.hdr.is_present("Contact") > 0
				and KSR.textops.search_hf("Contact", "x.signalwire.project", "f") > 0 then
			local xsp = KSR.pv.getw("$(ct{tobody.params}{param.value,+x.signalwire.project})");
			if string.len(xsp) < 10 then
				lbody = "{ \"username\": \"" .. KSR.pv.get("$fu")
						.. "\", \"domain\": \"" .. KSR.pv.get("$fd") .. "\"}";
			else
				if string.sub(xsp, 1, 1) == "\"" and string.sub(xsp, -1, -1) == "\"" then
					-- value is already quoted
					lbody = "{ \"username\": \"" .. KSR.pv.get("$fu")
						.. "\", \"domain\": \"" .. KSR.pv.get("$fd")
						.. "\", \"project\": " .. xsp
						.. "}";
				else
					lbody = "{ \"username\": \"" .. KSR.pv.get("$fu")
						.. "\", \"domain\": \"" .. KSR.pv.get("$fd")
						.. "\", \"project\": \"" .. xsp
						.. "\"}";
				end
			end
		else
			lbody = "{ \"username\": \"" .. KSR.pv.get("$fu")
					.. "\", \"domain\": \"" .. KSR.pv.get("$fd") .. "\"}";
		end
		KSR.pv.sets("$var(hres)", "");
		KSR.http_client.query_post_hdrs(AUTHURL, hbody,
				"Content-Type: application/json", "$var(hres)");

		local hres = KSR.pv.getw("$var(hres)");
		KSR.dbg("http query returned data: " .. hres .. "\n");
		if string.len(hres) < 10 then
			KSR.sl.sl_send_reply(500, "Backend unavailable");
			KSR.x.exit();
		end
		local jsres = cjson.decode(hres);
		if jsres["ha1"] == nil or string.len(jsres["ha1"]) < 10 then
			KSR.sl.sl_send_reply(500, "Profile unavailable");
			KSR.x.exit();
		end
		uapasswd = jsres["ha1"];
		if WITH_AUTHCACHE then
			KSR.pv.sets("$sht(auth=>$fU@$fd)", uapasswd);
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
	if KSR.nathelper.nat_uac_test(19)>0 then
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
		if not KSR.siputils.has_totag() then
			if KSR.tmx.t_is_branch_route()>0 then
				KSR.rr.add_rr_param(";nat=yes");
			end
		end
	end
	if KSR.siputils.is_reply()>0 then
		if KSR.isbflagset(FLB_NATB) then
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
	end
	KSR.x.exit();
end

-- User location service
function ksr_route_location()
	-- only for a set of domains
	local uard = KSR.pv.get("$rd");
	if DOMAINAUTH[uard] == nil then
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


-- Manage outgoing branches
-- equivalent of branch_route[...]{}
function ksr_branch_manage()
	KSR.dbg("new branch [".. KSR.pv.get("$T_branch_idx")
				.. "] to ".. KSR.pv.get("$ru") .. "\n");
	ksr_route_natmanage();
	return 1;
end

-- Manage incoming replies
-- equivalent of onreply_route[...]{}
function ksr_onreply_manage()
	KSR.dbg("incoming reply\n");
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
	-- round robin (4) dispatching on group 100
	if KSR.dispatcher.ds_select_dst(100, 4) < 0 then
		KSR.sl.send_reply(404, "No destination");
		KSR.x.exit();
	end

	KSR.dbg("--- SCRIPT: going to <" .. KSR.pv.get("$ru") .. "> via <"
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
