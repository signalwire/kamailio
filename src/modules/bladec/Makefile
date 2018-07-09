#
# WARNING: do not run this directly, it should be run by the master Makefile

include ../../Makefile.defs
auto_gen=
NAME=bladec.so

ifeq ($(CROSS_COMPILE),)
	BUILDER = $(shell which pkg-config)
ifneq ($(BUILDER),)
	PKGLIBUV = $(shell $(BUILDER) --exists libev > /dev/null 2>&1 ; echo $$? )
ifneq ($(PKGLIBUV),0)
	BUILDER =
endif
endif
endif

ifneq ($(BUILDER),)
	DEFS += $(shell $(BUILDER) --cflags signalwire_client)
	LIBS += $(shell $(BUILDER) --libs signalwire_client)
else
	DEFS += -I$(LOCALBASE)/include/signalwire-client-c -I$(SYSBASE)/include/signalwire-client-c
	LIBS += -L$(LOCALBASE)/lib -L$(SYSBASE)/lib -lsignalwire_client
endif

DEFS+=-DKAMAILIO_MOD_INTERFACE

include ../../Makefile.modules
