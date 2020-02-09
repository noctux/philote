#!/usr/bin/lua

local Ansible = require("ansible")
local ubus    = require("ubus")
local json    = require("dkjson")

function list(module)
	check_parameters(module, {"path"})
	local path = module:get_params()['path']

	local conn = module:ubus_connect()

	local list = {}

	local namespaces = conn:objects()
	if not namespaces then
		module:fail_json({msg="Failed to enumerate ubus"})
	end

	for _, n in ipairs(namespaces) do
		if not path or Ansible.contains(n, path) then
			local signatures = conn:signatures(n)
			if not signatures then
				module:fail_json({msg="Failed to enumerate ubus"})
			end
			list[n] = signatures
		end
	end

	conn:close()
	module:exit_json({msg="Gathered local signatures", signatures=list})
end

function call(module)
	check_parameters(module, {"path", "method", "message"})
	local p = module:get_params()
	local path = p["path"]
	if 1 ~= #path then
		module:fail_json({msg="Call only allows one path element, but zero or 2+ were given"})
	else
		path = path[1]
	end

	local conn = module:ubus_connect()
	local res  = module:ubus_call(conn, path, p['method'], p['message'])

	conn:close()
	module:exit_json({msg=string.format("Called %s.%s(%s)", path, p['method'], json.encode(p['message'])), result=res, changed=true})
end

function send(module)
	--     - send <type> [<message>]		Send an event
	check_parameters(module, {"type", "message"})
	local p = module:get_params()

	local conn = module:ubus_connect()

	local res, status = conn:send(p["type"], p["message"])
	if not res then
		module:fail_json({msg="Failed to send event", status=status})
	end

	conn:close()
	module:exit_json({msg="Event sent successfully", result=res, changed=true})
end

function facts(module)
	check_parameters(module, {})

	local conn = module:ubus_connect()

	local facts = {}

	local namespaces = conn:objects()
	for _,n in ipairs(namespaces) do
		if     "network.device" == n
			or 1 == string.find(n, "network.interface.")
			or "network.wireless" == n then
			facts[n] = module:ubus_call(conn, n, "status", {})
		elseif "service" == n then
			-- list {}
			facts[n] = module:ubus_call(conn, n, "list", {})
		elseif "system" == n then
			-- board {}
			-- info {}
			local f = {}
			f["board"] = module:ubus_call(conn, n, "board", {})
			f["info"]  = module:ubus_call(conn, n, "info", {})
			facts[n] = f
		elseif "uci" == n then
			-- configs {}
			-- foreach configs...
			local f = {}
			local configs = module:ubus_call(conn, n, "configs", {})['configs']
			f["configs"] = configs
			f["state"] = {}

			for _,conf in ipairs(configs) do
				-- TODO: transform unnamed sections to their anonymous names
				f["state"][conf] = module:ubus_call( conn, n, "state", {config=conf})['values']
			end
			facts[n] = f
		end
	end

	conn:close()

	module:exit_json({msg="All available facts gathered", ansible_facts=facts})
end

function check_parameters(module, valid)
	local p = module:get_params()
	local i = 0
	for k,_ in pairs(p) do
		-- not a buildin command and not a valid entry
		if      1 ~= string.find(k, "_ansible")
			and k ~= "socket" 
			and k ~= "timeout"
			and k ~= "command" then

			i = i+1

			if((not Ansible.contains(k, valid))) then
				module:fail_json({msg=string.format("Parameter %q invalid for command %s", k, p['command'])})
			end
		end
	end

	return i
end

function main(arg)
	-- module models the ubus cli tools structure
	--   Usage: ubus [<options>] <command> [arguments...]
	--   Options:
	--     -s <socket>:		Set the unix domain socket to connect to
	--     -t <timeout>:		Set the timeout (in seconds) for a command to complete
	--     -S:			Use simplified output (for scripts)
	--     -v:			More verbose output
	--    
	--    Commands:
	--     - list [<path>]			List objects
	--     - call <path> <method> [<message>]	Call an object method
	--     - send <type> [<message>]		Send an event

	local module = Ansible.new({
		command =  { aliases = {"cmd"}, required=true , choices={"list", "call", "send", "facts"}},
		path    =  { type="list" },
		method  =  { type="str" },
		type    =  { type="str" },
		message =  { type="jsonarg" },
		socket  =  { type="path" },
		timeout =  { type="int"}
	})

	module:parse(arg[1])

	local p = module:get_params()

	local dispatcher = {
		list = list,
		call = call,
		send = send,
		facts = facts
	}

	dispatcher[p['command']](module)
end

main(arg)
