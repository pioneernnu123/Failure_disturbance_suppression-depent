obj-m := phys_mem.o
phys_mem-y := main.o file_operations.o mmap_phys.o
ccflags-y += -I$(src)/include

KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: all clean
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
