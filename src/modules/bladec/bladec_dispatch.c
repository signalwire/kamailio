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

static int _bladec_notify_sockets[2];
static int _bladec_netstring_format = 1;

extern str _bladec_event_callback;
extern int _bladec_dispatcher_pid;
extern int _bladec_max_clients;

#define BLADEC_IPADDR_SIZE	64
#define BLADEC_TAG_SIZE	64
#define CLIENT_BUFFER_SIZE	32768
typedef struct _bladec_client {
	int connected;
	int sock;
	unsigned short af;
	unsigned short src_port;
	char src_addr[BLADEC_IPADDR_SIZE];
	char tag[BLADEC_IPADDR_SIZE];
	str  stag;
	char rbuffer[CLIENT_BUFFER_SIZE];
	unsigned int rpos;
} bladec_client_t;

typedef struct _bladec_env {
	int eset;
	int conidx;
	str msg;
} bladec_env_t;

typedef struct _bladec_msg {
	str data;
	str tag;
	int unicast;
} bladec_msg_t;

#define BLADEC_MAX_CLIENTS	_bladec_max_clients

/* last one used for error handling, not a real connected client */
static bladec_client_t *_bladec_clients = NULL;

typedef struct _bladec_evroutes {
	int con_new;
	str con_new_name;
	int con_closed;
	str con_closed_name;
	int msg_received;
	str msg_received_name;
} bladec_evroutes_t;

static bladec_evroutes_t _bladec_rts;

typedef struct _bladec_loop {
	int fd;
} bladec_loop_t;

typedef struct _bladec_io {
	int fd;
} bladec_io_t;

#define BLADEC_ERROR (-1)
#define BLADEC_READ (2)

extern str _bladec_config_path;

typedef struct baldec_globals {
	swclt_cfg_t lconfig;
	swclt_ident_t target_identity;
	char *target_identity_str;
} bladec_globals_t;

static bladec_globals_t _bladec_globals;

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
	status = swclt_cfg_lookup_identval(&_bladec_globals.lconfig, "target_identity", &_bladec_globals.target_identity);
	if(status != KS_STATUS_SUCCESS) {
		LM_ERR("failed to load target_identity key in config: %s\n", _bladec_config_path.s);
		goto error;
	}

	status = swclt_cfg_lookup_strval(&_bladec_globals.lconfig, "target_identity", &_bladec_globals.target_identity_str);
	if(status != KS_STATUS_SUCCESS) {
		LM_ERR("failed to load target_identity key in config: %s\n", _bladec_config_path.s);
		goto error;
	}

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
void bladec_io_start(bladec_loop_t *loop, bladec_io_t *watcher)
{
	return;
}

/**
 *
 */
void bladec_io_stop(bladec_loop_t *loop, bladec_io_t *watcher)
{
	return;
}

/**
 *
 */
void bladec_io_init(bladec_io_t *watcher, void *cbf, int csock, int mode)
{
	return;
}

/**
 *
 */
bladec_loop_t *bladec_default_loop(int mode)
{
	return NULL;
}

/**
 *
 */
bladec_loop_t *bladec_loop(bladec_loop_t *loop, int mode)
{
	return NULL;
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
void bladec_init_environment(int dformat)
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

	_bladec_netstring_format = dformat;
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
int bladec_close_connection(int cidx)
{
	if(cidx<0 || cidx>=BLADEC_MAX_CLIENTS || _bladec_clients==NULL)
		return -1;
	if(_bladec_clients[cidx].connected==1
			&& _bladec_clients[cidx].sock >= 0) {
		close(_bladec_clients[cidx].sock);
		_bladec_clients[cidx].connected = 0;
		_bladec_clients[cidx].sock = -1;
		return 0;
	}
	return -2;
}

/**
 *
 */
int bladec_cfg_close(sip_msg_t *msg)
{
	bladec_env_t *evenv;

	if(msg==NULL)
		return -1;

	evenv = bladec_get_msg_env(msg);

	if(evenv==NULL || evenv->conidx<0 || evenv->conidx>=BLADEC_MAX_CLIENTS)
		return -1;
	return bladec_close_connection(evenv->conidx);
}

/**
 *
 */
int bladec_set_tag(sip_msg_t* msg, str* stag)
{
	bladec_env_t *evenv;

	if(msg==NULL || stag==NULL || _bladec_clients==NULL)
		return -1;

	evenv = bladec_get_msg_env(msg);

	if(evenv==NULL || evenv->conidx<0 || evenv->conidx>=BLADEC_MAX_CLIENTS)
		return -1;

	if(!(_bladec_clients[evenv->conidx].connected==1
			&& _bladec_clients[evenv->conidx].sock >= 0)) {
		LM_ERR("connection not established\n");
		return -1;
	}

	if(stag->len>=BLADEC_TAG_SIZE) {
		LM_ERR("tag size too big: %d / %d\n", stag->len, BLADEC_TAG_SIZE);
		return -1;
	}
	_bladec_clients[evenv->conidx].stag.s = _bladec_clients[evenv->conidx].tag;
	strncpy(_bladec_clients[evenv->conidx].stag.s, stag->s, stag->len);
	_bladec_clients[evenv->conidx].stag.s[stag->len] = '\0';
	_bladec_clients[evenv->conidx].stag.len = stag->len;
	return 1;
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
int bladec_dispatch_notify(bladec_msg_t *emsg)
{
	int i;
	int n;
	int wlen;

	if(_bladec_clients==NULL) {
		return 0;
	}

	n = 0;
	for(i=0; i<BLADEC_MAX_CLIENTS; i++) {
		if(_bladec_clients[i].connected==1 && _bladec_clients[i].sock>=0) {
			if(emsg->tag.s==NULL || (emsg->tag.len = _bladec_clients[i].stag.len
						&& strncmp(_bladec_clients[i].stag.s,
									emsg->tag.s, emsg->tag.len)==0)) {
				wlen = write(_bladec_clients[i].sock, emsg->data.s,
						emsg->data.len);
				if(wlen!=emsg->data.len) {
					LM_DBG("failed to write all packet (%d out of %d) on socket"
							" %d index [%d]\n",
							wlen, emsg->data.len, _bladec_clients[i].sock, i);
				}
				n++;
				if (emsg->unicast){
					break;
				}
			}
		}
	}

	LM_DBG("the message was sent to %d clients\n", n);

	return n;
}

/**
 *
 */
void bladec_recv_client(bladec_loop_t *loop, bladec_io_t *watcher, int revents)
{
	ssize_t rlen;
	int i, k;
	bladec_env_t evenv;
	str frame;
	char *sfp;
	char *efp;

	if(BLADEC_ERROR & revents) {
		LM_ERR("received invalid event (%d)\n", revents);
		return;
	}
	if(_bladec_clients==NULL) {
		LM_ERR("no client structures\n");
		return;
	}

	for(i=0; i<BLADEC_MAX_CLIENTS; i++) {
		if(_bladec_clients[i].connected==1 && _bladec_clients[i].sock==watcher->fd) {
			break;
		}
	}
	if(i==BLADEC_MAX_CLIENTS) {
		LM_ERR("cannot lookup client socket %d\n", watcher->fd);
		/* try to empty the socket anyhow */
		rlen = recv(watcher->fd, _bladec_clients[i].rbuffer, CLIENT_BUFFER_SIZE-1, 0);
		return;
	}

	/* read message from client */
	rlen = recv(watcher->fd, _bladec_clients[i].rbuffer + _bladec_clients[i].rpos,
			CLIENT_BUFFER_SIZE - 1 - _bladec_clients[i].rpos, 0);

	if(rlen < 0) {
		LM_ERR("cannot read the client message\n");
		_bladec_clients[i].rpos = 0;
		return;
	}


	cfg_update();

	bladec_env_reset(&evenv);
	if(rlen == 0) {
		/* client is gone */
		evenv.eset = 1;
		evenv.conidx = i;
		bladec_run_cfg_route(&evenv, _bladec_rts.con_closed,
				&_bladec_rts.con_closed_name);
		_bladec_clients[i].connected = 0;
		if(_bladec_clients[i].sock>=0) {
			close(_bladec_clients[i].sock);
		}
		_bladec_clients[i].sock = -1;
		_bladec_clients[i].rpos = 0;
		bladec_io_stop(loop, watcher);
		free(watcher);
		LM_INFO("client closing connection - pos [%d] addr [%s:%d]\n",
				i, _bladec_clients[i].src_addr, _bladec_clients[i].src_port);
		return;
	}

	_bladec_clients[i].rbuffer[_bladec_clients[i].rpos+rlen] = '\0';

	LM_DBG("{%d} [%s:%d] - received [%.*s] (%d) (%d)\n",
		i, _bladec_clients[i].src_addr, _bladec_clients[i].src_port,
		(int)rlen, _bladec_clients[i].rbuffer+_bladec_clients[i].rpos,
		(int)rlen, (int)_bladec_clients[i].rpos);
	evenv.conidx = i;
	evenv.eset = 1;
	if(_bladec_netstring_format) {
		/* netstring decapsulation */
		k = 0;
		while(k<_bladec_clients[i].rpos+rlen) {
			frame.len = 0;
			while(k<_bladec_clients[i].rpos+rlen) {
				if(_bladec_clients[i].rbuffer[k]==' '
						|| _bladec_clients[i].rbuffer[k]=='\t'
						|| _bladec_clients[i].rbuffer[k]=='\r'
						|| _bladec_clients[i].rbuffer[k]=='\n')
					k++;
				else break;
			}
			if(k==_bladec_clients[i].rpos+rlen) {
				_bladec_clients[i].rpos = 0;
				LM_DBG("empty content\n");
				return;
			}
			/* pointer to start of whole frame */
			sfp = _bladec_clients[i].rbuffer + k;
			while(k<_bladec_clients[i].rpos+rlen) {
				if(_bladec_clients[i].rbuffer[k]>='0' && _bladec_clients[i].rbuffer[k]<='9') {
					frame.len = frame.len*10 + _bladec_clients[i].rbuffer[k] - '0';
				} else {
					if(_bladec_clients[i].rbuffer[k]==':')
						break;
					/* invalid character - discard the rest */
					_bladec_clients[i].rpos = 0;
					LM_DBG("invalid char when searching for size [%c] [%.*s] (%d) (%d)\n",
							_bladec_clients[i].rbuffer[k],
							(int)(_bladec_clients[i].rpos+rlen), _bladec_clients[i].rbuffer,
							(int)(_bladec_clients[i].rpos+rlen), k);
					return;
				}
				k++;
			}
			if(k==_bladec_clients[i].rpos+rlen || frame.len<=0) {
				LM_DBG("invalid frame len: %d kpos: %d rpos: %u rlen: %lu\n",
						frame.len, k, _bladec_clients[i].rpos, rlen);
				_bladec_clients[i].rpos = 0;
				return;
			}
			if(frame.len + k>=_bladec_clients[i].rpos + rlen) {
				/* partial data - shift back in buffer and wait to read more */
				efp = _bladec_clients[i].rbuffer + _bladec_clients[i].rpos + rlen;
				if(efp<=sfp) {
					_bladec_clients[i].rpos = 0;
					LM_DBG("weird - invalid size for residual data\n");
					return;
				}
				_bladec_clients[i].rpos = (unsigned int)(efp-sfp);
				if(efp-sfp > sfp-_bladec_clients[i].rbuffer) {
					memcpy(_bladec_clients[i].rbuffer, sfp, _bladec_clients[i].rpos);
				} else {
					for(k=0; k<_bladec_clients[i].rpos; k++) {
						_bladec_clients[i].rbuffer[k] = sfp[k];
					}
				}
				LM_DBG("residual data [%.*s] (%d)\n",
						_bladec_clients[i].rpos, _bladec_clients[i].rbuffer,
						_bladec_clients[i].rpos);
				return;
			}
			k++;
			frame.s = _bladec_clients[i].rbuffer + k;
			if(frame.s[frame.len]!=',') {
				/* invalid data - discard and reset buffer */
				LM_DBG("frame size mismatch the ending char (%c): [%.*s] (%d)\n",
						frame.s[frame.len], frame.len, frame.s, frame.len);
				_bladec_clients[i].rpos = 0 ;
				return;
			}
			frame.s[frame.len] = '\0';
			k += frame.len ;
			evenv.msg.s = frame.s;
			evenv.msg.len = frame.len;
			LM_DBG("executing event route for frame: [%.*s] (%d)\n",
						frame.len, frame.s, frame.len);
			bladec_run_cfg_route(&evenv, _bladec_rts.msg_received,
					&_bladec_rts.msg_received_name);
			k++;
		}
		_bladec_clients[i].rpos = 0 ;
	} else {
		evenv.msg.s = _bladec_clients[i].rbuffer;
		evenv.msg.len = rlen;
		bladec_run_cfg_route(&evenv, _bladec_rts.msg_received,
				&_bladec_rts.msg_received_name);
	}
}

/**
 *
 */
void bladec_accept_client(bladec_loop_t *loop, bladec_io_t *watcher, int revents)
{
	struct sockaddr caddr;
	socklen_t clen = sizeof(caddr);
	int csock;
	bladec_io_t *bladec_client;
	int i;
	bladec_env_t evenv;
	int optval;
	socklen_t optlen;

	if(_bladec_clients==NULL) {
		LM_ERR("no client structures\n");
		return;
	}
	bladec_client = (bladec_io_t*) malloc (sizeof(bladec_io_t));
	if(bladec_client==NULL) {
		LM_ERR("no more memory\n");
		return;
	}

	if(BLADEC_ERROR & revents) {
		LM_ERR("received invalid event\n");
		free(bladec_client);
		return;
	}

	cfg_update();

	/* accept new client connection */
	csock = accept(watcher->fd, (struct sockaddr *)&caddr, &clen);

	if (csock < 0) {
		LM_ERR("cannot accept the client '%s' err='%d'\n", gai_strerror(csock), csock);
		free(bladec_client);
		return;
	}
	for(i=0; i<BLADEC_MAX_CLIENTS; i++) {
		if(_bladec_clients[i].connected==0) {
			if (caddr.sa_family == AF_INET) {
				_bladec_clients[i].src_port = ntohs(((struct sockaddr_in*)&caddr)->sin_port);
				if(inet_ntop(AF_INET, &((struct sockaddr_in*)&caddr)->sin_addr,
							_bladec_clients[i].src_addr,
							BLADEC_IPADDR_SIZE)==NULL) {
					LM_ERR("cannot convert ipv4 address\n");
					close(csock);
					free(bladec_client);
					return;
				}
			} else {
				_bladec_clients[i].src_port = ntohs(((struct sockaddr_in6*)&caddr)->sin6_port);
				if(inet_ntop(AF_INET6, &((struct sockaddr_in6*)&caddr)->sin6_addr,
							_bladec_clients[i].src_addr,
							BLADEC_IPADDR_SIZE)==NULL) {
					LM_ERR("cannot convert ipv6 address\n");
					close(csock);
					free(bladec_client);
					return;
				}
			}
			optval = 1;
			optlen = sizeof(optval);
			if(setsockopt(csock, SOL_SOCKET, SO_KEEPALIVE,
						&optval, optlen) < 0) {
				LM_WARN("failed to enable keepalive on socket %d\n", csock);
			}
			_bladec_clients[i].connected = 1;
			_bladec_clients[i].sock = csock;
			_bladec_clients[i].af = caddr.sa_family;
			break;
		}
	}
	if(i>=BLADEC_MAX_CLIENTS) {
		LM_ERR("too many clients\n");
		close(csock);
		free(bladec_client);
		return;
	}

	LM_DBG("new connection - pos[%d] from: [%s:%d]\n", i,
			_bladec_clients[i].src_addr, _bladec_clients[i].src_port);

	bladec_env_reset(&evenv);
	evenv.conidx = i;
	evenv.eset = 1;
	bladec_run_cfg_route(&evenv, _bladec_rts.con_new, &_bladec_rts.con_new_name);

	if(_bladec_clients[i].connected == 0) {
		free(bladec_client);
		return;
	}

	/* start watcher to read messages from whatchers */
	bladec_io_init(bladec_client, bladec_recv_client, csock, BLADEC_READ);
	bladec_io_start(loop, bladec_client);
}

/**
 *
 */
void bladec_recv_notify(bladec_loop_t *loop, bladec_io_t *watcher, int revents)
{
	bladec_msg_t *emsg = NULL;
	int rlen;

	if(BLADEC_ERROR & revents) {
		perror("received invalid event\n");
		return;
	}

	cfg_update();

	/* read message from client */
	rlen = read(watcher->fd, &emsg, sizeof(bladec_msg_t*));

	if(rlen != sizeof(bladec_msg_t*) || emsg==NULL) {
		LM_ERR("cannot read the sip worker message\n");
		return;
	}

	LM_DBG("received [%p] [%.*s] (%d)\n", emsg,
			emsg->data.len, emsg->data.s, emsg->data.len);
	bladec_dispatch_notify(emsg);
	shm_free(emsg);
}

/**
 *
 */
int bladec_run_dispatcher(char *laddr, int lport)
{
	int bladec_srv_sock;
	struct sockaddr_in bladec_srv_addr;
	bladec_loop_t *loop;
	struct hostent *h = NULL;
	bladec_io_t io_server;
	bladec_io_t io_notify;
	int yes_true = 1;
	int fflags = 0;
	int i;

	LM_DBG("starting dispatcher processing\n");

	_bladec_clients = (bladec_client_t*)malloc(sizeof(bladec_client_t)
			* (BLADEC_MAX_CLIENTS+1));
	if(_bladec_clients==NULL) {
		LM_ERR("failed to allocate client structures\n");
		exit(-1);
	}
	memset(_bladec_clients, 0, sizeof(bladec_client_t) * BLADEC_MAX_CLIENTS);
	for(i=0; i<BLADEC_MAX_CLIENTS; i++) {
		_bladec_clients[i].sock = -1;
	}
	loop = bladec_default_loop(0);

	if(loop==NULL) {
		LM_ERR("cannot get libev loop\n");
		return -1;
	}

	h = gethostbyname(laddr);
	if (h == NULL || (h->h_addrtype != AF_INET && h->h_addrtype != AF_INET6)) {
		LM_ERR("cannot resolve local server address [%s]\n", laddr);
		return -1;
	}
	if(h->h_addrtype == AF_INET) {
		bladec_srv_sock = socket(PF_INET, SOCK_STREAM, 0);
	} else {
		bladec_srv_sock = socket(PF_INET6, SOCK_STREAM, 0);
	}
	if( bladec_srv_sock < 0 )
	{
		LM_ERR("cannot create server socket (family %d)\n", h->h_addrtype);
		return -1;
	}
	/* set non-blocking flag */
	fflags = fcntl(bladec_srv_sock, F_GETFL);
	if(fflags<0) {
		LM_ERR("failed to get the srv socket flags\n");
		close(bladec_srv_sock);
		return -1;
	}
	if (fcntl(bladec_srv_sock, F_SETFL, fflags | O_NONBLOCK)<0) {
		LM_ERR("failed to set srv socket flags\n");
		close(bladec_srv_sock);
		return -1;
	}

	bzero(&bladec_srv_addr, sizeof(bladec_srv_addr));
	bladec_srv_addr.sin_family = h->h_addrtype;
	bladec_srv_addr.sin_port   = htons((short)lport);
	bladec_srv_addr.sin_addr  = *(struct in_addr*)h->h_addr;

	/* Set SO_REUSEADDR option on listening socket so that we don't
	 * have to wait for connections in TIME_WAIT to go away before
	 * re-binding.
	 */

	if(setsockopt(bladec_srv_sock, SOL_SOCKET, SO_REUSEADDR,
		&yes_true, sizeof(int)) < 0) {
		LM_ERR("cannot set SO_REUSEADDR option on descriptor\n");
		close(bladec_srv_sock);
		return -1;
	}

	if (bind(bladec_srv_sock, (struct sockaddr*)&bladec_srv_addr,
				sizeof(bladec_srv_addr)) < 0) {
		LM_ERR("cannot bind to local address and port [%s:%d]\n", laddr, lport);
		close(bladec_srv_sock);
		return -1;
	}
	if (listen(bladec_srv_sock, 4) < 0) {
		LM_ERR("listen error\n");
		close(bladec_srv_sock);
		return -1;
	}
	bladec_io_init(&io_server, bladec_accept_client, bladec_srv_sock, BLADEC_READ);
	bladec_io_start(loop, &io_server);
	bladec_io_init(&io_notify, bladec_recv_notify, _bladec_notify_sockets[0], BLADEC_READ);
	bladec_io_start(loop, &io_notify);

	while(1) {
		bladec_loop (loop, 0);
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
int _bladec_relay(str *evdata, str *ctag, int unicast)
{
#define BLADEC_RELAY_FORMAT "%d:%.*s,"

	int len;
	int sbsize;
	bladec_msg_t *emsg;

	LM_DBG("relaying event data [%.*s] (%d)\n",
			evdata->len, evdata->s, evdata->len);

	sbsize = evdata->len;
	len = sizeof(bladec_msg_t)
		+ ((sbsize + 32 + ((ctag && ctag->len>0)?(ctag->len+2):0)) * sizeof(char));
	emsg = (bladec_msg_t*)shm_malloc(len);
	if(emsg==NULL) {
		LM_ERR("no more shared memory\n");
		return -1;
	}
	memset(emsg, 0, len);
	emsg->data.s = (char*)emsg + sizeof(bladec_msg_t);
	if(_bladec_netstring_format) {
		/* netstring encapsulation */
		emsg->data.len = snprintf(emsg->data.s, sbsize+32,
				BLADEC_RELAY_FORMAT,
				sbsize, evdata->len, evdata->s);
	} else {
		emsg->data.len = snprintf(emsg->data.s, sbsize+32,
				"%.*s",
				evdata->len, evdata->s);
	}
	if(emsg->data.len<=0 || emsg->data.len>sbsize+32) {
		shm_free(emsg);
		LM_ERR("cannot serialize event\n");
		return -1;
	}
	if(ctag && ctag->len>0) {
		emsg->tag.s = emsg->data.s + sbsize + 32;
		strncpy(emsg->tag.s, ctag->s, ctag->len);
		emsg->tag.len = ctag->len;
	}

	if (unicast){
		emsg->unicast = unicast;
	}

	LM_DBG("sending [%p] [%.*s] (%d)\n", emsg, emsg->data.len, emsg->data.s,
			emsg->data.len);
	if(_bladec_notify_sockets[1]!=-1) {
		len = write(_bladec_notify_sockets[1], &emsg, sizeof(bladec_msg_t*));
		if(len<=0) {
			shm_free(emsg);
			LM_ERR("failed to pass the pointer to bladec dispatcher\n");
			return -1;
		}
	} else {
		cfg_update();
		LM_DBG("dispatching [%p] [%.*s] (%d)\n", emsg,
				emsg->data.len, emsg->data.s, emsg->data.len);
		bladec_dispatch_notify(emsg);
		shm_free(emsg);
	}
	return 0;
}

/**
 *
 */
int bladec_relay(str *evdata)
{
	return _bladec_relay(evdata, NULL, 0);
}

/**
 *
 */
int bladec_relay_multicast(str *evdata, str *ctag){
	return _bladec_relay(evdata, ctag, 0);
}

/**
 *
 */
int bladec_relay_unicast(str *evdata, str *ctag){
	return _bladec_relay(evdata, ctag, 1);
}

#if 0
/**
 *
 */
int bladec_relay(str *event, str *data)
{
#define BLADEC_RELAY_FORMAT "%d:{\n \"event\":\"%.*s\",\n \"data\":%.*s\n},"

	int len;
	int sbsize;
	str *sbuf;

	LM_DBG("relaying event [%.*s] data [%.*s]\n",
			event->len, event->s, data->len, data->s);

	sbsize = sizeof(BLADEC_RELAY_FORMAT) + event->len + data->len - 13;
	sbuf = (str*)shm_malloc(sizeof(str) + ((sbsize+32) * sizeof(char)));
	if(sbuf==NULL) {
		LM_ERR("no more shared memory\n");
		return -1;
	}
	sbuf->s = (char*)sbuf + sizeof(str);
	sbuf->len = snprintf(sbuf->s, sbsize+32,
			BLADEC_RELAY_FORMAT,
			sbsize, event->len, event->s, data->len, data->s);
	if(sbuf->len<=0 || sbuf->len>sbsize+32) {
		shm_free(sbuf);
		LM_ERR("cannot serialize event\n");
		return -1;
	}

	len = write(_bladec_notify_sockets[1], &sbuf, sizeof(str*));
	if(len<=0) {
		LM_ERR("failed to pass the pointer to bladec dispatcher\n");
		return -1;
	}
	LM_DBG("sent [%p] [%.*s] (%d)\n", sbuf, sbuf->len, sbuf->s, sbuf->len);
	return 0;
}
#endif

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

	if(_bladec_clients==NULL) {
		return pv_get_null(msg, param, res);
	}
	evenv = bladec_get_msg_env(msg);

	if(evenv==NULL || evenv->conidx<0 || evenv->conidx>=BLADEC_MAX_CLIENTS)
		return pv_get_null(msg, param, res);

	if(_bladec_clients[evenv->conidx].connected==0
			&& _bladec_clients[evenv->conidx].sock < 0)
		return pv_get_null(msg, param, res);

	switch(param->pvn.u.isname.name.n)
	{
		case 0:
			return pv_get_sintval(msg, param, res, evenv->conidx);
		case 1:
			if(evenv->msg.s==NULL)
				return pv_get_null(msg, param, res);
			return pv_get_strval(msg, param, res, &evenv->msg);
		case 2:
			return pv_get_strzval(msg, param, res,
					_bladec_clients[evenv->conidx].src_addr);
		case 3:
			return pv_get_sintval(msg, param, res,
					_bladec_clients[evenv->conidx].src_port);
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
