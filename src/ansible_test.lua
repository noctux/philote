#!/usr/bin/env lua

local Ansible = require("ansible")

function main(arg)
	local module  = Ansible.new({
		required  = { required=true },
		choice    = { choices={"a", "b", "c", "d"} },
		alias     = { aliases={"al", "alia"}},
		default   = { default="a" },
		-- Types   str list dict bool int float path raw jsonarg
		string    = { type='str' },
		list      = { type='list' },
		bool      = { type='bool' },
		int       = { type='int' },
		float     = { type='float' },
		dict      = { type='dict' },
		path      = { type='path' },
		raw       = { type='raw' },
		jsonarg   = { type='jsonarg' },
		reqalias  = { aliases={"ra"}, required=true },
		defchoice = { default="foo", choices={"foo", "bar", "baz"}},
		defreq    = { default="bar", required=true },
		change    = { type='bool' },
		command   = {},
		binpath   = { type='dict' }
	})

	module:parse(arg[1])

	local p = module:get_params();

	if p["command"] then
		local rc, out, err = module:run_command(p["command"])
		if 0 == rc then
			module:exit_json({msg="Success", rc=rc, out=out, err=err})
		else
			module:fail_json({msg="Failure", rc=rc, out=out, err=err})
		end
	elseif p["binpath"] then
		local binspec = p["binpath"]
		local binpath = module:get_bin_path(binspec["name"], binspec["required"], binspec["candidates"])
		module:exit_json({msg="This is binpath", binpath=binpath})
	elseif p["change"] then
		module:exit_json({msg="This is an echo", changed=true})
	else
		module:exit_json({msg="This is an echo"})
	end
end

main(arg)
