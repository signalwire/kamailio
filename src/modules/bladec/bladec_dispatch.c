/**
 * Copyright (C) 2014 Daniel-Constantin Mierla (asipto.com)
 *
 * This file is part of Kamailio, a free SIP server.
 *
 * This file is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version
 *
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 */

#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>

#include <signalwire-client-c/client.h>
#include <signalwire-client-c/config.h>

#include "../../core/sr_module.h"
#include "../../core/dprint.h"
#include "../../core/ut.h"
#include "../../core/cfg/cfg_struct.h"
#include "../../core/kemi.h"
#include "../../core/fmsg.h"

#include "bladec_dispatch.h"

extern str _bladec_event_callback;

typedef struct _bladec_env {
	int eset;
	int conidx;
	str msg;
} bladec_env_t;

static int _bladec_notify_sockets[2];
extern int _bladec_dispatcher_pid;

typedef struct _bladec_evroutes {
	int con_new;
	str con_new_name;
	int con_closed;
	str con_closed_name;
	int msg_received;
	str msg_received_name;
} bladec_evroutes_t;

static bladec_evroutes_t _bladec_rts;

#define BLADEC_ERROR (-1)
#define BLADEC_READ (2)

extern str _bladec_config_path;

swclt_sess_t _bladec_session = {0};

typedef struct baldec_globals {
	swclt_cfg_t lconfig;
	swclt_ident_t target_identity;
	const char *target_identity_str;
	int istatus;
} bladec_globals_t;

static bladec_globals_t _bladec_globals = {0};

/**
 *
 */
int bladec_client_init(void)
{
	ks_status_t status;

	memset(&_bladec_globals, 0, sizeof(bladec_globals_t));

	swclt_init(KS_LOG_LEVEL_INFO);

	status = swclt_cfg_open_ex(&_bladec_globals.lconfig, _bladec_config_path.s, "local");
	if(status != KS_STATUS_SUCCESS) {
		LM_ERR("failed to open config: %s (%d)\n", _bladec_config_path.s, (int)status);
		return -1;
	}
	status = swclt_cfg_lookup_identval(_bladec_globals.lconfig, "target_identity", &_bladec_globals.target_identity);
	if(status != KS_STATUS_SUCCESS) {
		LM_ERR("failed to load target_identity key in config: %s\n", _bladec_config_path.s);
		goto error;
	}

	status = swclt_cfg_lookup_strval(_bladec_globals.lconfig, "target_identity", &_bladec_globals.target_identity_str);
	if(status != KS_STATUS_SUCCESS) {
		LM_ERR("failed to load target_identity key in config: %s\n", _bladec_config_path.s);
		goto error;
	}
	_bladec_globals.istatus = 1;

	LM_DBG("target identity string: %s\n", _bladec_globals.target_identity_str);

	return 0;

error:
	swclt_ident_destroy(&_bladec_globals.target_identity);
	ks_handle_destroy(&_bladec_globals.lconfig);

	if (swclt_shutdown()) {
		LM_ERR("shutdown was ungraceful\n");
	}
	return -1;
}

/**
 *
 */
int bladec_client_session_start(void)
{
	if(_bladec_globals.istatus != 1) {
		LM_ERR("config struct was not initialized\n");
		return -1;
	}
	LM_DBG("creating session to: %s\n", _bladec_globals.target_identity_str);
	swclt_sess_create(&_bladec_session, _bladec_globals.target_identity_str,
			_bladec_globals.lconfig);
	if(!_bladec_session) {
		LM_ERR("failed connecting to: %s\n", _bladec_globals.target_identity_str);
		return -1;
	}
	LM_DBG("connecting to: %s\n", _bladec_globals.target_identity_str);
	swclt_sess_connect(_bladec_session);
	LM_DBG("connected to: %s\n", _bladec_globals.target_identity_str);

	return 0;
}

/**
 *
 */
void bladec_env_reset(bladec_env_t *evenv)
{
	if(evenv==0)
		return;
	memset(evenv, 0, sizeof(bladec_env_t));
	evenv->conidx = -1;
}

/**
 *
 */
void bladec_init_environment(void)
{
	memset(&_bladec_rts, 0, sizeof(bladec_evroutes_t));

	_bladec_rts.con_new_name.s = "bladec:connection-new";
	_bladec_rts.con_new_name.len = strlen(_bladec_rts.con_new_name.s);
	_bladec_rts.con_new = route_lookup(&event_rt, "bladec:connection-new");
	if (_bladec_rts.con_new < 0 || event_rt.rlist[_bladec_rts.con_new] == NULL)
		_bladec_rts.con_new = -1;

	_bladec_rts.con_closed_name.s = "bladec:connection-closed";
	_bladec_rts.con_closed_name.len = strlen(_bladec_rts.con_closed_name.s);
	_bladec_rts.con_closed = route_lookup(&event_rt, "bladec:connection-closed");
	if (_bladec_rts.con_closed < 0 || event_rt.rlist[_bladec_rts.con_closed] == NULL)
		_bladec_rts.con_closed = -1;

	_bladec_rts.msg_received_name.s = "bladec:message-received";
	_bladec_rts.msg_received_name.len = strlen(_bladec_rts.msg_received_name.s);
	_bladec_rts.msg_received = route_lookup(&event_rt, "bladec:message-received");
	if (_bladec_rts.msg_received < 0 || event_rt.rlist[_bladec_rts.msg_received] == NULL)
		_bladec_rts.msg_received = -1;
}

/**
 *
 */
int bladec_run_cfg_route(bladec_env_t *evenv, int rt, str *rtname)
{
	int backup_rt;
	struct run_act_ctx ctx;
	sip_msg_t *fmsg;
	sip_msg_t tmsg;
	sr_kemi_eng_t *keng = NULL;

	if(evenv==0 || evenv->eset==0) {
		LM_ERR("bladec env not set\n");
		return -1;
	}

	if((rt<0) && (_bladec_event_callback.s==NULL || _bladec_event_callback.len<=0))
		return 0;

	fmsg = faked_msg_next();
	memcpy(&tmsg, fmsg, sizeof(sip_msg_t));
	fmsg = &tmsg;
	bladec_set_msg_env(fmsg, evenv);
	backup_rt = get_route_type();
	set_route_type(EVENT_ROUTE);
	init_run_actions_ctx(&ctx);
	if(rt>=0) {
		run_top_route(event_rt.rlist[rt], fmsg, 0);
	} else {
		keng = sr_kemi_eng_get();
		if(keng!=NULL) {
			if(keng->froute(fmsg, EVENT_ROUTE,
						&_bladec_event_callback, rtname)<0) {
				LM_ERR("error running event route kemi callback\n");
			}
		}
	}
	set_route_type(backup_rt);
	bladec_set_msg_env(fmsg, NULL);
	return 0;
}

/**
 *
 */
int bladec_init_notify_sockets(void)
{
	if (socketpair(PF_UNIX, SOCK_STREAM, 0, _bladec_notify_sockets) < 0) {
		LM_ERR("opening notify stream socket pair\n");
		return -1;
	}
	LM_DBG("inter-process event notification sockets initialized: %d ~ %d\n",
			_bladec_notify_sockets[0], _bladec_notify_sockets[1]);
	return 0;
}

/**
 *
 */
void bladec_close_notify_sockets_child(void)
{
	LM_DBG("closing the notification socket used by children\n");
	close(_bladec_notify_sockets[1]);
	_bladec_notify_sockets[1] = -1;
}

/**
 *
 */
void bladec_close_notify_sockets_parent(void)
{
	LM_DBG("closing the notification socket used by parent\n");
	close(_bladec_notify_sockets[0]);
	_bladec_notify_sockets[0] = -1;
}


/**
 *
 */
int bladec_run_dispatcher(char *laddr, int lport)
{
	LM_DBG("starting dispatcher processing\n");

	while(1) {
		sleep(3);
	}

	return 0;
}

/**
 *
 */
int bladec_run_worker(int prank)
{
	LM_DBG("started worker process: %d\n", prank);
	while(1) {
		sleep(3);
	}
}


/**
 *
 */
int bladec_relay(str *reqnodeid, str *resnodeid, str *evproto,
		str *evcmd, str *evdata)
{
	ks_status_t rcode;
	swclt_cmd_t rcmd;
	ks_json_t *result = NULL;
	ks_json_t *params = NULL;

	LM_DBG("relaying cmd - reqnodeid [%s] resnodeid [%s] evproto [%s]"
			" evcmd [%.*s] evdata [%.*s] (%d)\n",
			(reqnodeid->len>0)?reqnodeid->s:"none",
			(resnodeid->len>0)?resnodeid->s:"none",
			(evproto->len>0)?evproto->s:"none",
			evcmd->len, evcmd->s,
			evdata->len, evdata->s, evdata->len);

	params = ks_json_parse((const char *)evdata->s);

	rcode = swclt_sess_execute(_bladec_session,
				(reqnodeid->len>0)?reqnodeid->s:NULL,
				(resnodeid->len>0)?resnodeid->s:NULL,
				(evproto->len>0)?evproto->s:NULL,
				evcmd->s,
				&params,
				&rcmd);

	LM_DBG("res code: %ld\n", (long)rcode);

	swclt_cmd_result(rcmd, (const ks_json_t **)&result);

	if (!result) {
		LM_ERR("no result to command\n");
		goto error;
	}

	ks_handle_destroy(&rcmd);
	return 1;

error:
	ks_handle_destroy(&rcmd);
	return -1;
}

/**
 *
 */
int pv_parse_bladec_name(pv_spec_t *sp, str *in)
{
	if(sp==NULL || in==NULL || in->len<=0)
		return -1;

	switch(in->len)
	{
		case 3:
			if(strncmp(in->s, "msg", 3)==0)
				sp->pvp.pvn.u.isname.name.n = 1;
			else goto error;
		break;
		case 6:
			if(strncmp(in->s, "conidx", 6)==0)
				sp->pvp.pvn.u.isname.name.n = 0;
			else goto error;
		break;
		case 7:
			if(strncmp(in->s, "srcaddr", 7)==0)
				sp->pvp.pvn.u.isname.name.n = 2;
			else if(strncmp(in->s, "srcport", 7)==0)
				sp->pvp.pvn.u.isname.name.n = 3;
			else goto error;
		break;
		default:
			goto error;
	}
	sp->pvp.pvn.type = PV_NAME_INTSTR;
	sp->pvp.pvn.u.isname.type = 0;

	return 0;

error:
	LM_ERR("unknown PV msrp name %.*s\n", in->len, in->s);
	return -1;
}

/**
 *
 */
int pv_get_bladec(sip_msg_t *msg, pv_param_t *param, pv_value_t *res)
{
	bladec_env_t *evenv;

	if(param==NULL || res==NULL)
		return -1;

	if(_bladec_globals.istatus != 1) {
		return pv_get_null(msg, param, res);
	}
	evenv = bladec_get_msg_env(msg);

	switch(param->pvn.u.isname.name.n)
	{
		case 0:
			return pv_get_sintval(msg, param, res, 0);
		case 1:
			if(evenv->msg.s==NULL)
				return pv_get_null(msg, param, res);
			return pv_get_strval(msg, param, res, &evenv->msg);
		case 2:
			return pv_get_strzval(msg, param, res,
					"0.0.0.0");
		case 3:
			return pv_get_sintval(msg, param, res, 0);
		default:
			return pv_get_null(msg, param, res);
	}

	return 0;
}

/**
 *
 */
int pv_set_bladec(sip_msg_t *msg, pv_param_t *param, int op,
		pv_value_t *val)
{
	return 0;
}
