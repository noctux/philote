#!/usr/bin/lua

local Ansible = require("ansible")

function main(arg)
    local module = Ansible.new({
        data = { default="pong" },
    })

    module:parse(arg[1])

    local p = module:get_params()

    local data = p["data"]

    if "crash" == data then
        module:fail_json({ msg="boom" })
    else
        module:exit_json({ changed=false, ping=data })
    end
end

main(arg)
