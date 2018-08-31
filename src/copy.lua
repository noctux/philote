#!/usr/bin/lua
-- WANT_JSON

local Ansible = require("ansible")
local File    = require("fileutils")
local os      = require("os")


function adjust_recursive_directory_permissions(pre_existing_dir, new_directory_list, index, module, directory_args, changed)
	-- Walk the new directories list and make sure that permissions are as we would expect
	
	local changed = false
	
	if index <= #new_directory_list then
		local working_dir = File.join(pre_existing_dir, new_directory_list[i])
		directory_args['path'] = working_dir
		changed = File.set_fs_attributes_if_different(module, directory_args, changed, nil)
		changed = adjust_recursive_directory_permissions(working_dir, new_directory_list, index+1, module, directory_args, changed)
	end

	return changed
end

function main(arg)
	local module = Ansible.new(
		{ src   = { required=true }
		, _original_basename = { required=false }
		, content = { required=false }
		, path = {  aliases={'dest'}, required=true }
		, backup = { default=false, type='bool' }
		, force = { default=true, aliases={'thirsty'}, type='bool' }
		, validate = { required=false, type='str' }
		, directory_mode = { required=false }
		, remote_src = { required=false, type='bool' }
		-- sha256sum, to check if the copy was successful - currently ignored
		, checksum = {}


		-- file common args
		-- , src = {}
		, mode = { type='raw' }
		, owner = {}
		, group = {}

		-- Selinux to ignore
		, seuser = {}
		, serole = {}
		, selevel = {}
		, setype = {}

		, follow = {type='bool', default=false}

		-- not taken by the file module, but other modules call file so it must ignore them
		, content = {}
		, backup = {}
		-- , force = {}
		, remote_src = {}
		, regexp = {}
		, delimiter = {}
		-- , directory_mode = {}
		}
	)

	module:parse(arg[1])

	local p = module:get_params()

	local src  = File.expanduser(p['src'])
	local dest = File.expanduser(p['path'])
	local backup = p['backup']
	local force = p['force']
	local _original_basename = p['_original_basename']
	local validate = p['validate']
	local follow = p['follow']
	local mode = p['mode']
	local remote_src = p['remote_src']

	if not File.exists(src) then
		module:fail_json({msg="Source " .. src .. " not found"})
	end
	if not File.readable(src) then
		module:fail_json({msg="Source " .. src .. " not readable"})
	end
	if File.isdir(src) then
		module:fail_json({msg="Remote copy does not support recursive copy of directory: " .. src})
	end

	local checksum_src = File.sha1(module, src)
	local checksum_dest = nil
	local md5sum_src = File.md5(module, src)

	local changed = false

	-- Special handling for recursive copy - create intermediate dirs
	if _original_basename and string.match(dest, "/$") then
		dest = File.join(dest, orignal_basename)
		local dirname = File.dirname(dest)
		if not File.exists(dirname) and File.isabs(dirname) then
			local pre_existing_dir, new_directory_list = File.split_pre_existing_dir(dirname)
			File.mkdirs(dirname)
			local directory_args = p
			local direcotry_mode = p['directory_mode']
			adjust_recursive_directory_permissions(pre_existing_dir, new_directory_list, 1, module, directory_args, changed)
		end
	end

	if File.exists(dest) then
		if File.islnk(dest) and follow then
			dest = File.realpath(dest)
		end
		if not force then
			module:exit_json({msg="file already exists", src=src, dest=dest, changed=false})
		end
		if File.isdir(dest) then
			local basename = File.basename(src)
			if _original_basename then
				basename = _original_basename
			end
			dest = File.join(dest, basename)
		end
		if File.readable(dest) then
			checksum_dest = File.sha1(module, dest)
		end
	else
		if not File.exists(File.dirname(dest)) then
			if nil == File.stat(File.dirname(dest)) then
				module:fail_json({msg="Destination directory " .. File.dirname(dest) .. " is not accessible"})
			end
			module:fail_json({msg="Destination directory " .. File.dirname(dest) .. " does not exist"})
		end
	end

	if not File.writeable(File.dirname(dest)) then
		module:fail_json({msg="Destination " .. File.dirname(dest) .. " not writeable"})
	end

	local backup_file = nil
	if checksum_src ~= checksum_dest or File.islnk(dest) then
		if not module:check_mode() then
			if backup and File.exists(dest) then
				backup_file = module:backup_local(dest)
			end

			local function err(res, msg)
				if not res then
					module:fail_json({msg="failed to copy: " .. src .. " to " .. dest .. ": " .. msg})
				end
			end

			local res, msg
			-- allow for conversion from symlink
			if File.islnk(dest) then
				res, msg = File.unlink(dest)
				err(res, msg)
				res, msg = File.touch(dest)
				err(res, msg)
			end
			if validate then
				-- FIXME: Validate is currently unsupported
			end
			if remote_src then
				local tmpname, msg = File.mkstemp(File.dirname(dest) .. "/ansibltmp_XXXXXX")
				err(tmpname, msg)
				res, msg = module:copy(src, tmpdest)
				err(res, msg)
				res, msg = module:move(tmpdest, dest)
				err(res, msg)
			else
				res, msg = module:move(src, dest)
				err(res, msg)
			end
		end
		changed = true
	else
		changed = false
	end

	res_args = { dest=dest, src=src, md5sum=md5sum_src, checksum=checksum_src, changed=changed }
	if backup_file then
		res_args['backup_file'] = backup_file
	end

	p['dest'] = dest
	if not module:check_mode() then
		local file_args = p
		res_args['changed'] = File.set_fs_attributes_if_different(module, file_args, res_args['changed'], nil)
	end

	res_args['msg'] = "Dummy"

	module:exit_json(res_args)
end

main(arg)
