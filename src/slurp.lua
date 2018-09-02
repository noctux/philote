#!/usr/bin/lua

local Ansible = require("ansible")
local base64  = require("base64")

function main(arg)
	local module = Ansible.new({
		src = { required=true, type="path", aliases={"path"} },
	})

	module:parse(arg[1])

	local source = module:get_params()["src"]
	local content = module:slurp(source)
	local encoded = base64.encode(content)

	module:exit_json({content=encoded, source=source, encoding='base64'})
end

main(arg)
