#!/usr/bin/lua

local Ansible = require("ansible")
local File = require("fileutils")

function service_script(service)
    return "/etc/init.d/" .. service
end

function service_exists(service)
    return File.isfile(service_script(service))
end

function service_enabled(module, service)
    local rc, out, err = service_command(module, service, "enabled")

    return 0 == rc, out, err
end

function service_command(module, service, action)
    return module:run_command(service_script(service) .. " " .. action)
end

function service_running(module, service)
    if 0 == module:run_command("pgrep -P 1 " .. service) then
        return true
    end

    return false
end

function main(arg)
    local module = Ansible.new({
        name = { required = true },
        state = { choices = { "", "started", "stopped", "restarted", "reloaded" } },
        enabled = { type = 'bool' },
    })

    module:parse(arg[1])

    local p = module:get_params()

    local service = p["name"]
    local state = p["state"]
    local enable = p["enabled"]

    local changed = false
    local msg = {}
    local actions = {}

    if (state == nil or state == "") and (enable == nil) then
        module:fail_json({ msg = "at least one of 'state' and 'enabled' are required" })
    end

    if not service_exists(service) then
        module:fail_json({ msg = string.format("service '%s' does not exist", service) })
    end

    if enable then
        if not service_enabled(module, service) then
            actions[#actions + 1] = "enable"
        end
    elseif enable == false then
        if service_enabled(module, service) then
            actions[#actions + 1] = "disable"
        end
    end

    if state ~= nil then
        local action = string.gsub(state, "p?ed$", "")

        if not (("start" == action and service_running(module, service)) or ("stop" == action and not service_running(module, service))) then
            actions[#actions + 1] = action
        end
    end

    if #actions > 0 then
        if not module:check_mode() then
            for i = 1, #actions do
                local rc, out, err = service_command(module, service, actions[i])

                if rc ~= 0 then
                    module:fail_json({ msg = string.format("service '%s' has failed to %s", service, actions[i]),
                                       service = { rc = rc, out = out, err = err } })
                end

                msg[#msg + 1] = string.format("executed '%s' command", actions[i])
            end
        end
        changed = true
    end

    module:exit_json({ changed = changed, msg = table.concat(msg, "; ") })
end

main(arg)
