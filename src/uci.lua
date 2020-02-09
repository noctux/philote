#!/usr/bin/lua

local Ansible = require("ansible")
local ubus    = require("ubus")

function reload_configs(module)
	local conn = module:ubus_connect()

	local res  = module:ubus_call(conn, "uci", "reload_config", {})

	conn:close()
	module:exit_json({msg="Configs reloaded", result=res})
end

function get_configs(module)
	local conn = module:ubus_connect()

	local res  = module:ubus_call(conn, "uci", "configs", {})

	conn:close()
	module:exit_json({msg="Configs fetched", result=res})
end

function docommit(module, conn, config)
	local conf, sec = check_config(module, conn, config, nil)

	local res = module:ubus_call(conn, "uci", "commit", {config=conf})

	return res
end

function commit(module)
	local conn = module:ubus_connect()
	local path = module:get_params()["name"]

	local configs
	if path == nil then
		local conf = module:ubus_call(conn, "uci", "configs", {})
		configs = conf['configs']
	else
		if path["option"] or path["section"] then
			module:fail_json({msg="Only whole configs can be committed"})
		end

		configs = { path["config"] }
	end

	local res = {}
	for _, conf in ipairs(configs) do
		res[#res + 1] = docommit(module, conn, conf)
	end

	module:exit_json({msg="Committed all changes for " .. #configs ..  " configurations", changed=true, result=res})
end

function get(module)
	local conn = module:ubus_connect()
	local p = module:get_params()
	local path = p["name"]

	local msg = {config=path["config"]}
	if p["match"] ~= nil then
		msg["match"] = p["match"]
	end
	if p["type"] ~= nil then
		msg["type"] = p["type"]
	end
	if path["section"] ~= nil then
		msg["section"] = path["section"] 
	end

	local res = module:ubus_call(conn, "uci", "get", msg)

	module:exit_json({msg="Got config", changed=false, result=res})
end

function revert(module)
	local conn = module:ubus_connect()
	local path = module:get_params()["name"]

	local configs
	if path == nil then
		local conf = module:ubus_call(conn, "uci", "configs", {})
		configs = conf['configs']
	else
		local conf, sec = check_config(module, conn, path["config"], nil)
		configs = { conf }
	end

	local res = {}
	for _, conf in ipairs(configs) do
		res[#res + 1] = module:ubus_call(conn, "uci", "revert", {config=conf})
	end

	module:exit_json({msg="Successfully reverted all staged changes for " .. #configs .. " configurations", changed=true, result=res})
end

function parse_path(module)
	local path = module:get_params()['name']
	-- a path consists of config.section.option

	-- lua's pattern engine does not seem to be expressive enough to do this in one go
	local config, section, option
	if string.match(path, "([^.]+)%.([^.]+)%.([^.]+)") then
		config, section, option = string.match(path, "([^.]+)%.([^.]+)%.([^.]+)")
	elseif string.match(path, "([^.]+)%.([^.]+)") then
		config, section = string.match(path, "([^.]+)%.([^.]+)")
	else
		config = path
	end

	local pathobject = {config=config, section=section, option=option}
	return pathobject
end

function query_value(module, conn, path, unique)
	local res  = conn:call("uci", "get", path)

	if nil == res then
		return nil
	end

	if unique and nil ~= res["values"] then
		module:fail_json({msg="Path specified is amiguos and matches multiple options", path=path, result=res})
	end

	if res["values"] then
		return res["values"]
	else
		return res["value"]
	end
end

function check_config(module, conn, config, section)
	local res  = module:ubus_call(conn, "uci", "configs", {})

	if not module.contains(config, res["configs"]) then
		module:fail_json({msg="Invalid config " .. config})
	end

	if nil ~= section then
		res = module:ubus_call(conn, "uci", "get", {config=config, section=section})
		if res and res["values"] and res["values"][".type"] then
			return config, section
		end
	end

	return config, nil
end

function compare_tables(a, b)
	if a == nil or b == nil then
		return a == b
	end

	if type(a) ~= "table" then
		if type(b) ~= "table" then
			return a == b
		end
		return false
	end
	if #a ~= #b then
		return false
	end
	-- level 1 compare
	table.sort(a)
	table.sort(b)
	for i,v in ipairs(a) do
		if v ~= b[i] then
			return false
		end
	end

	return true
end

function set_value(module)
	local p    = module:get_params()
	local path = p["name"]

	local conn = module:ubus_connect()

	local conf, sec = check_config(module, conn, path["config"], path["section"])

	local target = p["value"]
	local forcelist = p["forcelist"]

	if type(target) == "table" and #target == 1 and not forcelist then
		target = target[1]
	end

	local values = {}
	if path["option"] then
		values[path["option"]] = target
	end

	local res
	if nil ~= p["match"] then
		local preres = module:ubus_call(conn, "uci", "changes", {config=conf})
		local prechanges = preres["changes"] or {}

		local message = {
			config=conf,
			values=p["values"],
			match=p["match"]
		}
		res = module:ubus_call(conn, "uci", "set", message) or {}

		-- Since 'uci changes' returns changes in the order they were made,
		-- determine what the 'set' command changed by stripping off the
		-- first #prechanges entries from the postchanges.
		local postres = module:ubus_call(conn, "uci", "changes", {config=conf})
		local postchanges = postres["changes"] or {}
		for i = #prechanges, 1, -1 do
			table.remove(postchanges, i)
		end
		res["changes"] = postchanges

		conn:close()
		if #postchanges > 0 then
			module:exit_json({msg="Changes made", changed=true, result=res})
		end
		module:exit_json({msg="No changes made", changed=false, result=res})
	elseif not sec then
		-- We have to create a section and use "uci add"
		if not p["type"] then
			module:fail_json({msg="when creating sections, a type is required", message=message})
		end

		local message = {
			config=conf,
			name=path["section"],
			type=p["type"],
		}

		if path["option"] then
			message["values"]=values
		end

		res = module:ubus_call(conn, "uci", "add", message)

	elseif not compare_tables(target, query_value(module, conn, path, true)) then
		-- We have to take actions and use "uci set"
		local message = {
			config=conf,
			section=sec,
			values=values
		}
		res = module:ubus_call(conn, "uci", "set", message)
	else
		conn:close()
		module:exit_json({msg="Value already set", changed=false, result=res})
	end


	local autocommit = false
	if p["autocommit"] then
		autocommit = true
		docommit(module, conn, conf)
	end

	conn:close()
	module:exit_json({msg="Value successfully set", changed=true, autocommit=autocommit, result=res})
end

function unset_value(module)
	local p    = module:get_params()
	local path = p["name"]

	local conn = module:ubus_connect()

	local conf, sec = check_config(module, conn, path["config"], path["section"])

	-- the whole section is already gone
	if nil == sec then
		-- already absent
		conn:close()
		module:exit_json({msg="Section already absent", changed=false})
	end

	-- and nil ~= sec...
	local message = {
		config=conf,
		section=sec
	}

	-- check if we have got a option
	if path["option"] then
		local is     = query_value(module, conn, path, false)
		if not is then
			conn:close()
			module:exit_json({msg="Option already absent", changed=false})
		end

		message["option"] = path["option"]
	end


	local res = module:ubus_call(conn, "uci", "delete", message)

	local autocommit = false
	if p["autocommit"] then
		local autocommit = true
		docommit(module, conn, conf)
	end

	conn:close()
	module:exit_json({msg="Section successfully deleted", changed=true, autocommit=autocommit, result=res})
end

function check_parameters(module)
	local p = module:get_params()

	-- Validate the path
	if p["name"] then
		p["name"] = parse_path(module, p["name"])
	end

	-- op requires that no state is given, configs does not take any parameter
	if p["op"] then
		-- all operands do not take a state or value parameter
		if p["value"] then
			module:fail_json({msg="op=* do not work with 'state','value' or 'autocommit' arguments"})
		end

		-- config does not take a path parameter
		if "configs" == p["op"] and p["name"] then
			module:fail_json({msg="'op=config' does not take a 'path' argument"})
		end
	else
		-- in the normal case name and state are required
		if    (not p["name"])
		   or (not p["state"]) then
			module:fail_json({msg="Both name and state are required to set/unset values"})
		end

		-- when performing an "uci set", a value is required
		if ("set" == p["state"] or "present" == p["state"]) then
			if p["name"]["option"] and  not p["value"] then  -- Setting a regular value
				module:fail_json({msg="When using 'uci set', a value is required"})
			elseif not p["name"]["option"] and not p["type"] and not p["match"] then -- Creating a section
				module:fail_json({msg="When creating sections with 'uci set', a type is required"})
			end
		end

		if nil ~= p["value"] and ("unset" == p["state"] or "absent" == p["state"]) then
			module:fail_json({msg="When deleting options, no value can be set"})
		end

		if nil ~= p["forcelist"] and  ("unset" == p["state"] or "absent" == p["state"]) then
			module:fail_json({msg="'forcelist' only applies to set operations"})
		end
	end

end

function main(arg)
	local module = Ansible.new({
		name       = { aliases = {"path", "key"}, type="str"},
		value      = { type="list" },
		state      = { default="present", choices={"present", "absent", "set", "unset"} },
		op         = { choices={"configs", "commit", "revert", "get"} },
		reload     = { aliases = {"reload_configs", "reload-configs"}, type='bool'},
		autocommit = { default=true, type="bool" },
		forcelist  = { default=false, type="bool" },
		type       = { aliases = {"section-type"}, type="str" },
		socket     = { type="path" },
		timeout    = { type="int"},
		match      = { type="dict"},
		values     = { type="dict"}
	})

	module:parse(arg[1])
	check_parameters(module)

	local p = module:get_params()

	if p["reload"] then
		reload_configs(module)
	end

	-- Execute operation
	if     "configs" == p["op"] then
		get_configs(module)
	elseif "commit"  == p["op"] then
		commit(module)
	elseif "revert"  == p["op"] then
		revert(module)
	elseif "get"  == p["op"] then
		get(module)
	else
		-- If no op was given, simply enforce the setting state
		local state = p["state"]
		local doset = true
		if "absent" == state or "unset" == state then
			doset = false
		elseif "present" ~= state and "set" ~= state then
  			module:fail_json({msg="Set state must be one of set, present, unset, absent"})
		end

		-- check if a full path was specified
		local path = p["name"]
		if not path["config"] then
  			module:fail_json({msg="Set operation requires a path"})
        end
  		if not path["section"] then
		  	if doset and not p["type"] and not p["match"] then
				module:fail_json({msg="Set operation requires a type, a match, or a path of"
					.. " the form '<config>.<section>[.<option>]'", parsed=pathobject})
			elseif not doset then
				module:fail_json({msg="Set absent operation requires a path of"
					.. " the form '<config>.<section>[.<option>]'", parsed=pathobject})
			end
  		end

		-- Do the ops
		if doset then
			set_value(module)
		else
			unset_value(module)
		end
	end
end

main(arg)
