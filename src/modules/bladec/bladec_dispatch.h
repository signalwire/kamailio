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

#ifndef _BLADEC_DISPATCH_
#define _BLADEC_DISPATCH_

#include "../../core/pvar.h"

int bladec_init_notify_sockets(void);

void bladec_close_notify_sockets_child(void);

void bladec_close_notify_sockets_parent(void);

int bladec_run_dispatcher();

int bladec_run_worker(int prank);

int bladec_relay(str *reqnodeid, str *evproto, str *evcmd, str *evdata);

void bladec_init_environment(void);

int pv_parse_bladec_name(pv_spec_t *sp, str *in);
int pv_get_bladec(sip_msg_t *msg,  pv_param_t *param, pv_value_t *res);
int pv_set_bladec(sip_msg_t *msg, pv_param_t *param, int op,
		pv_value_t *val);

/* set bladec env to shortcut of hdr date - not used in faked msg */
#define bladec_set_msg_env(_msg, _evenv) do { _msg->date=(hdr_field_t*)_evenv; } while(0)
#define bladec_get_msg_env(_msg) ((bladec_env_t*)_msg->date)

int bladec_cfg_close(sip_msg_t *msg);
int bladec_set_tag(sip_msg_t* msg, str* stag);

int bladec_client_init(void);

int bladec_client_session_start(void);

#endif
