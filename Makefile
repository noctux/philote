.PHONY: all

all: ./library/copywrt.lua ./library/filewrt.lua ./library/lineinfile.lua ./library/opkg.lua ./library/statwrt.lua ./library/ubus.lua ./library/uci.lua

WHITELIST=io,os,posix.,ubus
FATPACKARGS=--whitelist $(WHITELIST) --truncate

./library/%.lua : ./src/%.lua ./src/*.lua
	./src/fatpack.pl --input $^ --output $(dir $@) $(FATPACKARGS)
