# SPDX-License-Identifier: MPL-2.0
# Cross-build the installed Linux client. Run from this directory:
#   make CC=aarch64-linux-musl-gcc
# The module headers are the reviewed additive video ABI and broker wire
# contract; the build never copies or embeds host code.
CC ?= aarch64-linux-musl-gcc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wno-unused-parameter
FLOE_VIDEO_INC ?= ../../../Modules/FloeLinuxVideo/Sources
CPPFLAGS += -D_GNU_SOURCE -I$(FLOE_VIDEO_INC)/FloeLinuxVideoNative/include \
            -I$(FLOE_VIDEO_INC)/FloeLinuxVideoBroker/include
LDFLAGS ?= -static

floe-codec: floe_codec.c floe_codec_broker.c floe_codec_v4l2.c floe_codec_broker.h floe_codec_v4l2.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ floe_codec.c floe_codec_broker.c floe_codec_v4l2.c $(LDFLAGS)

clean:
	rm -f floe-codec

.PHONY: clean
