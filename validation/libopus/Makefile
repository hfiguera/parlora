ERTS_INCLUDE_DIR ?= $(shell erl +S 1 -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
OPUS_FLAGS := $(shell pkg-config --cflags opus)
OPUS_LIBS := $(shell pkg-config --libs opus)
UNAME := $(shell uname -s)
NIF_FLAGS := -fPIC -shared
ifeq ($(UNAME),Darwin)
NIF_FLAGS += -undefined dynamic_lookup
endif

.PHONY: all clean
all: priv/opus_probe.so

priv/opus_probe.so: c_src/opus_probe.c
	mkdir -p priv
	$(CC) $(CFLAGS) -O2 -std=c11 -Wall -Wextra -Werror $(NIF_FLAGS) -I$(ERTS_INCLUDE_DIR) $(OPUS_FLAGS) $< -o $@ $(LDFLAGS) $(OPUS_LIBS)

clean:
	rm -f priv/opus_probe.so
