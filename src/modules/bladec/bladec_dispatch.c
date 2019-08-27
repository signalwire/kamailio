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
#include "../../core/pt.h"
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
swclt_hmon_t _bladec_session_monitor = {0};

#define BLADE_BOOTSTRAP_SIZE 1024

typedef struct baldec_globals {
	swclt_config_t *swcfg;
	ks_json_t *jcfg;
	swclt_sess_t swses;
	char blade_bootstrap[BLADE_BOOTSTRAP_SIZE];
	char *swres;
	int istatus;
	int sstatus;
} bladec_globals_t;

static bladec_globals_t _bladec_globals = {0};

ks_json_t *bladec_load_json_config_file(char *cfgpath)
{
	ks_json_t *jcfg = NULL;
	ks_size_t lob = 1024;
	char *buf = NULL;
	ks_size_t eob = 0;
	FILE *fp = NULL;

	buf = ks_pool_alloc(NULL, lob);
	if(buf==NULL) {
		LM_ERR("failure to allocate ks pool memory\n");
		return NULL;
	}

	if (!(fp = fopen(cfgpath, "r"))) {
		LM_ERR("could not open config file: %s\n", cfgpath);
		return NULL;
	}

	while (!feof(fp)) {
		ks_size_t consumed = 0;
		ks_size_t available = lob - eob;
		if (available <= 1) {
			lob *= 2;
			buf = ks_pool_resize(NULL, lob);
			available = lob - eob;
		}
		consumed = fread(buf + eob, 1, available - 1, fp);
		eob += consumed;
	}
	fclose(fp);
	buf[eob] = '\0';

	jcfg = ks_json_parse(buf);
	ks_pool_free(&buf);

	return jcfg;
}

/**
 *
 */
int bladec_client_process_init(void)
{
	memset(&_bladec_globals, 0, sizeof(bladec_globals_t));
	return 0;
}

/**
 *
 */
int bladec_client_prepare(void)
{
	const char *tmp = NULL;

	if(_bladec_globals.istatus != 0) {
		return 0;
	}

	swclt_init(KS_LOG_LEVEL_DEBUG);

	_bladec_globals.jcfg = bladec_load_json_config_file(_bladec_config_path.s);
	if(_bladec_globals.jcfg == NULL) {
		LM_ERR("failed to load and parse config file\n");
		goto error;
	}

	swclt_config_create(&_bladec_globals.swcfg);

	strncpy(_bladec_globals.blade_bootstrap, "switchblade",
			sizeof(_bladec_globals.blade_bootstrap));
	if (_bladec_globals.jcfg
			&& (tmp = ks_json_get_object_cstr(_bladec_globals.jcfg,
					"blade_bootstrap"))) {
		if (tmp[0]) {
			strncpy(_bladec_globals.blade_bootstrap, tmp,
					sizeof(_bladec_globals.blade_bootstrap));
		}
	}
	if ((tmp = getenv("KAMAILIO_BLADE_BOOTSTRAP"))) {
		strncpy(_bladec_globals.blade_bootstrap, tmp,
				sizeof(_bladec_globals.blade_bootstrap));
	}
	swclt_config_load_from_json(_bladec_globals.swcfg, _bladec_globals.jcfg);
	swclt_config_load_from_env(_bladec_globals.swcfg);

	LM_DBG("blade bootstrap string: %s\n", _bladec_globals.blade_bootstrap);

	_bladec_globals.istatus = 1;

	return 0;

error:
	if (swclt_shutdown()) {
		LM_ERR("shutdown was ungraceful\n");
	}
	return -1;
}

static void bladec_session_state_handler(swclt_sess_t sess,
			swclt_hstate_change_t *sinfo, const char *cbdata)
{
	SWCLT_HSTATE old_state = sinfo->old_state;
	SWCLT_HSTATE new_state = sinfo->new_state;

	LM_DBG("SignalWire Session State Change (%d => %d): %s\n",
			old_state, new_state, swclt_hstate_describe_change(sinfo));

	if (new_state == SWCLT_HSTATE_ONLINE) {
		LM_DBG("Connected with NEW session\n");
	} else if (new_state == SWCLT_HSTATE_OFFLINE) {
		LM_DBG("Disconnected\n");
	}
}


/**
 *
 */
int bladec_client_session_start(void)
{
	ks_status_t status;
	if(_bladec_globals.istatus == 0) {
		LM_ERR("config struct was not initialized\n");
		return -1;
	}
	if(_bladec_globals.sstatus != 0) {
		LM_DBG("session was already initialized\n");
		return 0;
	}
	LM_DBG("creating session to: %s\n", _bladec_globals.blade_bootstrap);
	swclt_sess_create(&_bladec_session, _bladec_globals.blade_bootstrap,
			_bladec_globals.swcfg);
	if(!_bladec_session) {
		LM_ERR("failed connecting to: %s\n", _bladec_globals.blade_bootstrap);
		return -1;
	}
	swclt_hmon_register(&_bladec_session_monitor, _bladec_session,
			bladec_session_state_handler, NULL);

	LM_DBG("connecting to: %s\n", _bladec_globals.blade_bootstrap);
	status = swclt_sess_connect(_bladec_session);
	LM_DBG("connected to: %s (status: %d)\n",
			_bladec_globals.blade_bootstrap, status);

	_bladec_globals.sstatus = 1;

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
int bladec_relay(str *reqnodeid, str *evproto, str *evcmd, str *evdata)
{
	ks_status_t rcode;
	swclt_cmd_t rcmd;
	ks_json_t *result = NULL;
	ks_json_t *params = NULL;
	int cmdattempt = 0;

	if(evcmd==NULL || evcmd->s==NULL || evcmd->len<=0) {
		LM_ERR("invalid event cmd parameter\n");
		return -1;
	}
	if(evdata==NULL || evdata->s==NULL || evdata->len<=0) {
		LM_ERR("invalid event data parameter\n");
		return -1;
	}
	if(bladec_client_prepare()<0) {
		LM_ERR("failed to prepare the blade connector client\n");
		return -1;
	}
	if(_bladec_globals.istatus != 1) {
		LM_ERR("config struct was not initialized\n");
		return -1;
	}
	if(bladec_client_session_start()<0) {
		LM_ERR("failed to create blade session for process %d\n", my_pid());
		return -1;
	}
	if(_bladec_globals.swres) {
		ks_json_free_ex((void**)(&_bladec_globals.swres));
		_bladec_globals.swres = NULL;
	}
	if (!swclt_sess_connected(_bladec_session)) {
		LM_DBG("session is not connected\n");
		//return -1;
	}

	LM_DBG("relaying cmd - reqnodeid [%s] evproto [%s]"
			" evcmd [%.*s] evdata [%.*s] (%d)\n",
			(reqnodeid->len>0)?reqnodeid->s:"none",
			(evproto->len>0)?evproto->s:"none",
			evcmd->len, evcmd->s,
			evdata->len, evdata->s, evdata->len);

	params = ks_json_parse((const char *)evdata->s);
	if(params==NULL) {
		LM_ERR("failed to parse event data (%d): [%.*s]\n",
				evdata->len, evdata->len, evdata->s);
		return -1;
	}

cmdretry:
	rcode = swclt_sess_execute(_bladec_session,
				(reqnodeid->len>0)?reqnodeid->s:NULL,
				(evproto->len>0)?evproto->s:NULL,
				evcmd->s,
				&params,
				&rcmd);

	LM_DBG("res code: %ld\n", (long)rcode);

	swclt_cmd_result(rcmd, (const ks_json_t **)&result);

	if (!result) {
		if(cmdattempt!=0) {
			LM_WARN("no result to command (attempt: %d)\n", cmdattempt);
			goto error;
		} else {
			LM_DBG("no result to command (attempt: %d)\n", cmdattempt);
			cmdattempt++;

			ks_handle_destroy(&rcmd);
			goto cmdretry;
		}
	}

	_bladec_globals.swres = ks_json_print(result);
	if(_bladec_globals.swres) {
		LM_DBG("json result:\n%s\n",
				(_bladec_globals.swres)?_bladec_globals.swres:"<empty>");
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
int bladec_channel_broadcast(str *evproto, str *evchannel, str *evname,
		str *evdata)
{
	ks_json_t *params = NULL;

	if(_bladec_globals.istatus != 1) {
		LM_ERR("config struct was not initialized\n");
		return -1;
	}

	if(_bladec_globals.swres) {
		ks_json_free_ex((void**)(&_bladec_globals.swres));
		_bladec_globals.swres = NULL;
	}
	if (!swclt_sess_connected(_bladec_session)) {
		LM_DBG("session is not connected\n");
		//return -1;
	}

	LM_DBG("relaying cmd - evproto [%s] evchannel [%s]"
			" evname [%.*s] evdata [%.*s] (%d)\n",
			(evproto->len>0)?evproto->s:"none",
			(evchannel->len>0)?evchannel->s:"none",
			evname->len, evname->s,
			evdata->len, evdata->s, evdata->len);

	params = ks_json_parse((const char *)evdata->s);

	swclt_sess_broadcast(_bladec_session, evproto->s, evchannel->s, evname->s,
			&params);

	return 1;
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
			if(strncmp(in->s, "res", 3)==0)
				sp->pvp.pvn.u.isname.name.n = 1;
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
	LM_DBG("local event env: %p\n", evenv);

	switch(param->pvn.u.isname.name.n)
	{
		case 1:
			if(_bladec_globals.swres==NULL)
				return pv_get_null(msg, param, res);
			return pv_get_strzval(msg, param, res, _bladec_globals.swres);
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
