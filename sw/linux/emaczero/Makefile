# SPDX-License-Identifier: GPL-2.0-only OR Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# Out-of-tree build of the emacZero netdev driver:
#   make KDIR=<configured kernel tree> ARCH=arm64 CROSS_COMPILE=aarch64-linux-
# KDIR defaults to the running kernel's build directory.

obj-m += emaczero.o

ifeq ($(KERNELRELEASE),)
KDIR ?= /lib/modules/$(shell uname -r)/build

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: modules clean
endif
