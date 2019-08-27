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

#include "../../core/sr_module.h"
#include "../../core/dprint.h"
#include "../../core/ut.h"
#include "../../core/pt.h"
#include "../../core/pvar.h"
#include "../../core/mem/shm_mem.h"
#include "../../core/mod_fix.h"
#include "../../core/pvar.h"
#include "../../core/cfg/cfg_struct.h"
#include "../../core/kemi.h"
#include "../../core/fmsg.h"

#include "../../modules/tm/tm_load.h"

#include "bladec_dispatch.h"

MODULE_VERSION

static int   _bladec_workers = 1;

str _bladec_event_callback = STR_NULL;
int _bladec_dispatcher_pid = -1;
str _bladec_config_path = STR_NULL;
int _bladec_cwait_interval = 0;
int _bladec_cwait_usleep = 500;

static tm_api_t tmb;

static int  mod_init(void);
static int  child_init(int);
static void mod_destroy(void);

static int w_bladec_relay(sip_msg_t* msg, char* reqnid, char* evproto,
		char* evcmd, char* evdata);
static int w_bladec_async_relay(sip_msg_t* msg, char* reqnid, char* evproto,
		char* evcmd, char* evdata);
static int w_bladec_channel_broadcast(sip_msg_t* msg, char* evproto,
		char * evchannel, char* evname, char* evdata);

static cmd_export_t cmds[]={
	{"bladec_relay",		(cmd_function)w_bladec_relay,
		4, fixup_spve_all, 0, ANY_ROUTE},
	{"bladec_async_relay",	(cmd_function)w_bladec_async_relay,
		4, fixup_spve_all, 0, REQUEST_ROUTE},
	{"bladec_channel_broadcast",	(cmd_function)w_bladec_channel_broadcast,
		4, fixup_spve_all, 0, ANY_ROUTE},
	{0, 0, 0, 0, 0, 0}
};

static param_export_t params[]={
	{"workers",           PARAM_INT,   &_bladec_workers},
	{"event_callback",    PARAM_STR,   &_bladec_event_callback},
	{"config",            PARAM_STR,   &_bladec_config_path},
	{"cwait_interval",    PARAM_INT,   &_bladec_cwait_interval},
	{"cwait_usleep",      PARAM_INT,   &_bladec_cwait_usleep},
	{0, 0, 0}
};

static pv_export_t mod_pvs[] = {
	{ {"bladec", (sizeof("bladec")-1)}, PVT_OTHER, pv_get_bladec,
		pv_set_bladec, pv_parse_bladec_name, 0, 0, 0},

	{ {0, 0}, 0, 0, 0, 0, 0, 0, 0 }
};


struct module_exports exports = {
	"bladec",       /* module name */
	DEFAULT_DLFLAGS, /* dlopen flags */
	cmds,           /* exported function */
	params,         /* exported parameters */
	0,              /* exported rpc functions */
	mod_pvs,        /* exported pseudo-variables */
	0,              /* response processing function */
	mod_init,       /* module init function */
	child_init,     /* per child init function */
	mod_destroy     /* module destroy function */
};



/**
 * init module function
 */
static int mod_init(void)
{
	if(_bladec_config_path.s==NULL || _bladec_config_path.len<=0) {
		LM_ERR("path to config file not provided\n");
		return -1;
	}

	/* init faked sip msg */
	if(faked_msg_init()<0) {
		LM_ERR("failed to init faked sip message\n");
		return -1;
	}

	if(load_tm_api( &tmb ) < 0) {
		LM_INFO("cannot load the TM module functions - async relay disabled\n");
		memset(&tmb, 0, sizeof(tm_api_t));
	}

	if(_bladec_cwait_interval  < 0) {
		LM_WARN("connect wait interval param value is negative - resetting\n");
		_bladec_cwait_interval = 0;
	}
	if(_bladec_cwait_usleep  <= 0) {
		LM_WARN("connect wait usleep param value is invalid - resetting\n");
		_bladec_cwait_usleep = 500;
	}

	/* add space for one extra process */
	register_procs(1 + _bladec_workers);

	/* add child to update local config framework structures */
	cfg_register_child(1 + _bladec_workers);

	bladec_init_environment();

	return 0;
}

/**
 * @brief Initialize async module children
 */
static int child_init(int rank)
{
	int pid;
	int i;

	if (rank==PROC_INIT) {
		if(bladec_init_notify_sockets()<0) {
			LM_ERR("failed to initialize notify sockets\n");
			return -1;
		}
		return 0;
	}

	if (rank!=PROC_MAIN) {
		if(_bladec_dispatcher_pid!=getpid()) {
			bladec_close_notify_sockets_parent();
		}

		if(bladec_client_process_init()<0) {
			LM_ERR("failed to init the blade connector client\n");
			return -1;
		}
		return 0;
	}

	pid=fork_process(PROC_NOCHLDINIT, "BladeC Dispatcher", 1);
	if (pid<0)
		return -1; /* error */
	if(pid==0) {
		/* child */
		_bladec_dispatcher_pid = getpid();

		/* initialize the config framework */
		if (cfg_child_init())
			return -1;
		/* do child init to allow execution of rpc like functions */
		if(init_child(PROC_RPC) < 0) {
			LM_DBG("failed to do RPC child init for dispatcher\n");
			return -1;
		}
		/* main function for dispatcher */
		bladec_close_notify_sockets_child();
		if(bladec_run_dispatcher()<0) {
			LM_ERR("failed to initialize bladec dispatcher process\n");
			return -1;
		}
	}

	for(i=0; i<_bladec_workers; i++) {
		pid=fork_process(PROC_RPC, "BladeC Worker", 1);
		if (pid<0)
			return -1; /* error */
		if(pid==0) {
			/* child */

			/* initialize the config framework */
			if (cfg_child_init())
				return -1;
			/* main function for workers */
			if(bladec_run_worker(i+1)<0) {
				LM_ERR("failed to initialize worker process: %d\n", i);
				return -1;
			}
		}
	}

	return 0;
}
/**
 * destroy module function
 */
static void mod_destroy(void)
{
}

/**
 *
 */
static int w_bladec_relay(sip_msg_t* msg, char* reqnid, char* evproto,
		char* evcmd, char* evdata)
{
	str sreqnid = STR_NULL;
	str sproto = STR_NULL;
	str scmd = STR_NULL;
	str sdata = STR_NULL;

	if(evcmd==NULL || evdata==0) {
		LM_ERR("invalid parameters\n");
		return -1;
	}

	if(fixup_get_svalue(msg, (gparam_t*)reqnid, &sreqnid)!=0) {
		LM_ERR("unable to get reqnodeid\n");
		return -1;
	}

	if(fixup_get_svalue(msg, (gparam_t*)evproto, &sproto)!=0) {
		LM_ERR("unable to get proto\n");
		return -1;
	}

	if(fixup_get_svalue(msg, (gparam_t*)evcmd, &scmd)!=0) {
		LM_ERR("unable to get cmd\n");
		return -1;
	}
	if(scmd.s==NULL || scmd.len == 0) {
		LM_ERR("invalid cmd parameter\n");
		return -1;
	}
	if(fixup_get_svalue(msg, (gparam_t*)evdata, &sdata)!=0) {
		LM_ERR("unable to get data\n");
		return -1;
	}
	if(sdata.s==NULL || sdata.len == 0) {
		LM_ERR("invalid data parameter\n");
		return -1;
	}

	if(bladec_relay(&sreqnid, &sproto, &scmd, &sdata)<0) {
		LM_ERR("failed to relay event - cmd [%.*s] data [%.*s]\n",
				scmd.len, scmd.s, sdata.len, sdata.s);
		return -1;
	}

	return 1;
}

/**
 *
 */
static int w_bladec_async_relay(sip_msg_t* msg, char* reqnid, char* evproto,
		char* evcmd, char* evdata)
{
	str sreqnid = STR_NULL;
	str sproto = STR_NULL;
	str scmd = STR_NULL;
	str sdata = STR_NULL;
	unsigned int tindex;
	unsigned int tlabel;
	tm_cell_t *t = 0;

	if(evcmd==NULL || evdata==0) {
		LM_ERR("invalid parameters\n");
		return -1;
	}

	if(tmb.t_suspend==NULL) {
		LM_ERR("bladec async relay is disabled - tm module not loaded\n");
		return -1;
	}

	t = tmb.t_gett();
	if (t==NULL || t==T_UNDEFINED)
	{
		if(tmb.t_newtran(msg)<0)
		{
			LM_ERR("cannot create the transaction\n");
			return -1;
		}
		t = tmb.t_gett();
		if (t==NULL || t==T_UNDEFINED)
		{
			LM_ERR("cannot lookup the transaction\n");
			return -1;
		}
	}
	if(tmb.t_suspend(msg, &tindex, &tlabel)<0)
	{
		LM_ERR("failed to suspend request processing\n");
		return -1;
	}

	LM_DBG("transaction suspended [%u:%u]\n", tindex, tlabel);

	if(fixup_get_svalue(msg, (gparam_t*)reqnid, &sreqnid)!=0) {
		LM_ERR("unable to get reqnodeid\n");
		return -1;
	}

	if(fixup_get_svalue(msg, (gparam_t*)evproto, &sproto)!=0) {
		LM_ERR("unable to get proto\n");
		return -1;
	}

	if(fixup_get_svalue(msg, (gparam_t*)evcmd, &scmd)!=0) {
		LM_ERR("unable to get cmd\n");
		return -1;
	}
	if(scmd.s==NULL || scmd.len == 0) {
		LM_ERR("invalid cmd parameter\n");
		return -1;
	}
	if(fixup_get_svalue(msg, (gparam_t*)evdata, &sdata)!=0) {
		LM_ERR("unable to get data\n");
		return -1;
	}
	if(sdata.s==NULL || sdata.len == 0) {
		LM_ERR("invalid data parameter\n");
		return -1;
	}

	if(bladec_relay(&sreqnid, &sproto, &scmd, &sdata)<0) {
		LM_ERR("failed to relay event - cmd [%.*s] data [%.*s]\n",
				scmd.len, scmd.s, sdata.len, sdata.s);
		return -1;
	}

	return 1;
}

/**
 *
 */
static int ki_bladec_relay(sip_msg_t *msg, str *reqnodeid, str *evproto,
		str *evcmd, str *evdata)
{
	return bladec_relay(reqnodeid, evproto, evcmd, evdata);
}

static int w_bladec_channel_broadcast(sip_msg_t* msg, char* evproto,
		char * evchannel, char* evname, char* evdata)
{
	str sproto = STR_NULL;
	str schannel = STR_NULL;
	str sname = STR_NULL;
	str sdata = STR_NULL;

	if(evproto==NULL || evchannel==0 || evname==NULL) {
		LM_ERR("invalid parameters\n");
		return -1;
	}

	if(fixup_get_svalue(msg, (gparam_t*)evproto, &sproto)!=0) {
		LM_ERR("unable to get proto\n");
		return -1;
	}
	if(fixup_get_svalue(msg, (gparam_t*)evchannel, &schannel)!=0) {
		LM_ERR("unable to get channel\n");
		return -1;
	}
	if(fixup_get_svalue(msg, (gparam_t*)evname, &sname)!=0) {
		LM_ERR("unable to get event name\n");
		return -1;
	}
	if(sname.s==NULL || sname.len == 0) {
		LM_ERR("invalid cmd parameter\n");
		return -1;
	}
	if(fixup_get_svalue(msg, (gparam_t*)evdata, &sdata)!=0) {
		LM_ERR("unable to get data\n");
		return -1;
	}
	if(sdata.s==NULL || sdata.len == 0) {
		LM_ERR("invalid data parameter\n");
		return -1;
	}

	if(bladec_channel_broadcast(&sproto, &schannel, &sname, &sdata)<0) {
		LM_ERR("failed to relay event - evname [%.*s] data [%.*s]\n",
				sname.len, sname.s, sdata.len, sdata.s);
		return -1;
	}

	return 1;
}


/**
 *
 */
static int ki_bladec_channel_broadcast(sip_msg_t *msg, str *evproto,
		str *evchannel, str *evname, str *evdata)
{
	return bladec_channel_broadcast(evproto, evchannel, evname, evdata);
}

/**
 *
 */
/* clang-format off */
static sr_kemi_t sr_kemi_bladec_exports[] = {
	{ str_init("bladec"), str_init("relay"),
		SR_KEMIP_INT, ki_bladec_relay,
		{ SR_KEMIP_STR, SR_KEMIP_STR, SR_KEMIP_STR,
			SR_KEMIP_STR, SR_KEMIP_NONE, SR_KEMIP_NONE }
	},
	{ str_init("bladec"), str_init("channel_broadcast"),
		SR_KEMIP_INT, ki_bladec_channel_broadcast,
		{ SR_KEMIP_STR, SR_KEMIP_STR, SR_KEMIP_STR,
			SR_KEMIP_STR, SR_KEMIP_NONE, SR_KEMIP_NONE }
	},

	{ {0, 0}, {0, 0}, 0, NULL, { 0, 0, 0, 0, 0, 0 } }
};
/* clang-format on */

/**
 *
 */
int mod_register(char *path, int *dlflags, void *p1, void *p2)
{
	sr_kemi_modules_add(sr_kemi_bladec_exports);
	return 0;
}

