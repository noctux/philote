.PHONY: all

all: ./library/copy.lua ./library/file.lua ./library/lineinfile.lua ./library/opkg.lua ./library/slurp.lua ./library/stat.lua ./library/ubus.lua ./library/uci.lua

WHITELIST=io,os,posix.,ubus
FATPACKARGS=--whitelist $(WHITELIST) --truncate

./library/%.lua : ./src/%.lua ./src/*.lua
	./src/fatpack.pl --input $^ --output $(dir $@) $(FATPACKARGS)
