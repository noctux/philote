#!/usr/bin/lua
-- WANT_JSON

local Ansible = require("ansible")
local base64  = require("base64")

function main(arg)
	local module = Ansible.new({
		src = { required=true, aliases={"path"} },
	})

	module:parse(arg[1])

	local source = module:get_params()["src"]

	-- FIXME: add IO error handling
	local file = io.open(source, "rb")
	local content = file:read "*a"
	file:close()

	local encoded = base64.encode(content)

	module:exit_json({content=encoded, source=source, encoding='base64'})
end

main(arg)