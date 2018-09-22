#!/usr/bin/lua

local Ansible = require("ansible")

function update_package_db(module, opkg_path)
	local rc, out, err = module:run_command(string.format("%s update", opkg_path))

	if rc ~= 0 then
		module:fail_json({msg = "could not update package db", opkg={rc=rc, out=out, err=err}})
	end
end

function query_package(module, opkg_path, name)
	local rc, out, err = module:run_command(string.format("%s list-installed", opkg_path))

	if rc ~= 0 then
		module:fail_json({msg = "failed to list installed packages", opkg={rc=rc, out=out, err=err}})
	end

	for line in string.gmatch(out, "[^\n]+") do
		if name == string.match(line, "^(%S+)%s") then
			return true
		end
	end

	return false
end

function get_force(force)
	if force and string.len(force) > 0 then
		return "--force-" .. force
	else
		return ""
	end
end

function remove_packages(module, opkg_path, packages)
	local p = module:get_params()

	local force = get_force(p["force"])

	local remove_c = 0

	for _,package in ipairs(packages) do
		-- Query the package first, to see if we even need to remove
		if query_package(module, opkg_path, package) then
			if not module:check_mode() then
				local rc, out, err = module:run_command(string.format("%s remove %s %q", opkg_path, force, package))

				if rc ~= 0 or query_package(module, opkg_path, package) then
					module:fail_json({msg="failed to remove " .. package, opkg={rc=rc, out=out, err=err}})
				end
			end

			remove_c = remove_c + 1;
		end
	end

	if remove_c > 0 then
		module:exit_json({changed=true, msg=string.format("removed %d package(s)", remove_c)})
	else
		module:exit_json({changed=false, msg="package(s) already absent"})
	end
end

function install_packages(module, opkg_path, packages)
	local p = module:get_params()

	local force = get_force(p["force"])

	local install_c = 0

	for _,package in ipairs(packages) do
		-- Query the package first, to see if we even need to remove
		if not query_package(module, opkg_path, package) then
			if not module:check_mode() then
				local rc, out, err = module:run_command(string.format("%s install %s %s", opkg_path, force, package))

				if rc ~= 0 or not query_package(module, opkg_path, package) then
					module:fail_json({msg=string.format("failed to install %s", package), opkg={rc=rc, out=out, err=err}})
				end
			end

			install_c = install_c + 1;
		end
	end

	if install_c > 0 then
		module:exit_json({changed=true, msg=string.format("installed %s packages(s)", install_c)})
	else
		module:exit_json({changed=false, msg="package(s) already present"})
	end
end

function last_cache_update_timestamp(module)
	local rc, stdout, stderr = module:run_command("date +%s -r /tmp/opkg-lists")
	if rc ~= 0 then
		return nil
	else
		return tonumber(stdout)
	end
end

function current_timestamp(module)
	local rc, stdout, stderr = module:run_command("date +%s")
	return tonumber(stdout)
end

function cache_age(module)
	local last_update = last_cache_update_timestamp(module)
	if last_update == nil then
		return nil
	else
		return current_timestamp(module) - last_update
	end
end

function should_update_cache(module)
	if module.params.update_cache then
		return true
	end
	if module.params.cache_valid_time ~= nil then
		local age = cache_age(module)
		if age == nil then
			return true
		end
		if age > module.params.cache_valid_time then
			return true
		end
	end
	return false
end

function update_cache_if_needed(module, opkg_path)
	if should_update_cache(module) and not module:check_mode() then
		update_package_db(module, opkg_path)
	end
end

function main(arg)
	local module = Ansible.new({
		name =  { aliases = {"pkg"}, required=true , type='list'},
		state = { default = "present", choices={"present", "installed", "absent", "removed"} },
		force = { default = "", choices={"", "depends", "maintainer", "reinstall", "overwrite", "downgrade", "space", "postinstall", "remove", "checksum", "removal-of-dependent-packages"} } ,
		update_cache = { default = "no", aliases={ "update-cache" }, type='bool' },
		cache_valid_time = { type='int' }
	})

	local opkg_path = module:get_bin_path('opkg', true, {'/bin'})

	module:parse(arg[1])

	local p = module:get_params()

	update_cache_if_needed(module, opkg_path)
	
	local state     = p["state"]
	local packages  = p["name"]
	if "present" == state or "installed" == state then
		install_packages(module, opkg_path, packages)
	elseif "absent" == state or "removed" == state then
		remove_packages(module, opkg_path, packages)
	end
end

main(arg)
