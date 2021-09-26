.PHONY: all 

APP_NAME=fatpacker
WHITELIST=io,os,posix.,ubus
FATPACKARGS=--whitelist $(WHITELIST) --truncate

# LOCAL DEFAULT TASKS
all: ./library/copy.lua ./library/file.lua ./library/lineinfile.lua ./library/opkg.lua ./library/ping.lua ./library/slurp.lua ./library/stat.lua ./library/ubus.lua ./library/uci.lua

./library/%.lua : ./src/%.lua ./src/*.lua
	./src/fatpack.pl --input $^ --output $(dir $@) $(FATPACKARGS)
	
# DOCKER TASKS
# Build the container
build: ## Build the container
	docker build -t $(APP_NAME) .

run: ## Run container 
	docker run -i -t -v ${PWD}/library:/app/libary --rm --name="$(APP_NAME)" $(APP_NAME)

