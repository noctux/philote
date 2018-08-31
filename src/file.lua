#!/usr/bin/lua
-- WANT_JSON

local Ansible = require("ansible")
local File    = require("fileutils")
local Errno   = require("posix.errno")
local unistd  = require("posix.unistd")
local time    = require("posix.time")

local function get_state(path)
	-- Find the current state

	if File.lexists(path) then
		local stat = File.stat(path)
		if File.islnk(path) then
			return 'link'
		elseif File.isdir(path) then
			return 'directory'
		elseif stat ~= nil and stat['st_nlink'] > 1 then
			return 'hard'
		else
			-- could be many other things but defaulting to file
			return 'file'
		end
	end

	return 'absent'
end

local function append(t1, t2)
	for k,v in ipairs(t2) do
		t1[#t1 + 1] = v
	end
	return t1
end

local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local function recursive_set_attributes(module, path, follow, file_args)
	local changed = false
	local out = {}
	for _, entry in ipairs(File.walk(path, false)) do
		local root    = entry['root']
		local fsobjs  = append(entry['dirs'], entry['files'])

		for _, fsobj in ipairs(fsobjs) do
			fsname = File.join(root, {fsobj})
			out[#out + 1] = fsname

			if not File.islnk(fsname) then
				local tmp_file_args = deepcopy(file_args)
				tmp_file_args['path'] = fsname
				changed = changed or File.set_fs_attributes_if_different(module, tmp_file_args, changed, nil)
			else
				local tmp_file_args = deepcopy(file_args)
				tmp_file_args['path'] = fsname
				changed = changed or File.set_fs_attributes_if_different(module, tmp_file_args, changed, nil)
				if follow then
					fsname = File.join(root, {File.readlink(fsname)})
					if File.isdir(fsname) then
						changed = changed or recursive_set_attributes(module, fsname, follow, file_args)
					end
					tmp_file_args = deepcopy(file_args)
					tmp_file_args['path'] = fsname
					changed = changed or File.set_fs_attributes_if_different(module, tmp_file_args, changed, nil)
				end
			end
		end
	end

	return changed
end

local function strip(str, chars)
	str = string.gsub(str, string.format("^[%s]+", chars), "")
	str = string.gsub(str, string.format("[%s]+$", chars), "")
	return str
end

local function lstrip(str, chars)
	return string.gsub(str, string.format("^[%s]+", chars), "")
end

local function rstrip(str, chars)
	return string.gsub(str, string.format("[%s]+$", chars), "")
end

local function split(str, delimiter)
	local toks = {}

	for tok in string.gmatch(str, "[^".. delimiter .. "]+") do
		toks[#toks + 1] = tok
	end

	return toks
end

function main(arg)
	local module = Ansible.new(
		{ state = { choices={'file', 'directory', 'link', 'hard', 'touch', 'absent' } }
		, path = { aliases={'dest', 'name'}, required=true }
		, _original_basename = { required=false }
		, recurse = { default=false, type='bool' }
		, force = { required=false, default=false, type='bool' }
		, diff_peek = {}
		, validate = { required=false }
		, src = {required=false}

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
		, force = {}
		, remote_src = {}
		, regexp = {}
		, delimiter = {}
		, directory_mode = {}
		}
	)

	module:parse(arg[1])

	-- FIXME: properly implement checkmode handling in module
	--        NB: This module is already capable of performing check_mode
	local checkmode = false

	local params = module:get_params()

	local state = params['state']
	local force = params['force']
	local diff_peek = params['diff_peek']
	local src = params['src']
	local follow = params['follow']

	-- modify source as we later reload and pass, specially relevant when used by other modules
	path = File.expanduser(params['path'])
	params['path'] = path

	-- short-circuit for diff_peek
	if nil ~= diff_peek then
		local appears_binary = false

		local f, err = io.open(path, "r")
		if f ~= nil then
			local content = f:read(8192)
			if Ansible.contains('\x00', content) then
				appears_binary = true
			end
		end

		module.exit_json({path=path, changed=False, msg="Dummy", appears_binary=appears_binary})
	end

	prev_state = get_state(path)

	-- state should default to file, but since that creates many conflicts
	-- default to 'current' when it exists
	if nil == state then
		if prev_state ~= 'absent' then
			state = prev_state
		else
			state = 'file'
		end
	end

	-- source is both the source of a symlink or an informational passing of the src for a template module
	-- or copy module, even if this module never uses it, it is needed to key off some things
	if src ~= nil then
		src = File.expanduser(src)
	else
		if 'link' == state or 'hard' == state then
			if follow and 'link' == state then
				-- use the current target of the link as the source
				src = File.realpath(path)
			else
				module:fail_json({msg='src and dest are required for creating links'})
			end
		end
	end

	-- _original_basename is used by other modules that depend on file
	if File.isdir(path) and ("link" ~= state and "absent" ~= state) then
		local basename = nil
		if params['_original_basename'] then
			basename = params['_original_basename']
		elseif src ~= nil then
			basename = File.basename(src)
		end
		if basename then
			path = File.join(path, {basename})
			params['path'] = path
		end
	end

	-- make sure the target path is a directory when we're doing a recursive operation
	local recurse = params['recurse']
	if recurse and state ~= 'directory' then
		module:fail_json({path=path, msg="recurse option requires state to be directory"})
	end

	-- File args are inlined...
	local changed = false
	local diff = { before = {path=path}
	             , after  = {path=path}}

	local state_change = false
	if prev_state ~= state then
		diff['before']['state'] = prev_state
		diff['after']['state'] = state
		state_change = true
	end

	if state == 'absent' then
		if state_change then
			if not check_mode then
				if prev_state == 'directory' then
					local err = File.rmtree(path, {ignore_errors=false})
					if err then
						module:fail_json({msg="rmtree failed"})
					end
				else
					local status, errstr, errno = File.unlink(path)
					if not status then
						module:fail_json({path=path, msg="unlinking failed: " .. errstr})
					end
				end
			end
			module:exit_json({path=path, changed=true, msg="dummy", diff=diff})
		else
			module:exit_json({path=path, changed=false, msg="dummy"})
		end
	elseif state == 'file' then
		if state_change then
			if follow and prev_state == 'link' then
				-- follow symlink and operate on original
				path = File.realpath(path)
				prev_state = get_state(path)
				path['path'] = path
			end
		end

		if prev_state ~= 'file' and prev_state ~= 'hard' then
			-- file is not absent and any other state is a conflict
			module:fail_json({path = path, msg=string.format("file (%s) is %s, cannot continue", path, prev_state)})
		end

		changed = File.set_fs_attributes_if_different(module, params, changed, diff)
		module:exit_json({path=path, changed=changed, msg="dummy", diff=diff})
	elseif state == 'directory' then
		if follow and prev_state == 'link' then
			path = File.realpath(path)
			prev_state = get_state(path)
		end

		if prev_state == 'absent' then
			if module:check_mode() then
				module:exit_json({changed=true, msg="dummy", diff=diff})
			end
			changed = true
			local curpath = ''

			-- Split the path so we can apply filesystem attributes recursively
			-- from the root (/) directory for absolute paths or the base path
			-- of a relative path.  We can then walk the appropriate directory
			-- path to apply attributes.

			local segments = split(strip(path, '/'), '/')
			for _, dirname in ipairs(segments) do
				curpath = curpath .. '/' .. dirname
				-- remove lieading slash if we're creating a relative path
				if not File.isabs(path) then
					curpath = lstrip(curpath, "/")
				end
				if not File.exists(curpath) then
					local status, errstr, errno = File.mkdir(path)
					if not status then
						if not (errno == Errno.EEXIST and File.isdir(curpath)) then
							module:fail_json({path=path, msg="There was an issue creating " .. curpath .. " as requested: " .. errstr})
						end
					end
					tmp_file_args = deepcopy(params)
					tmp_file_args['path'] = curpath
					changed = File.set_fs_attributes_if_different(module, params, changed, diff)
				end
			end
		elseif prev_state ~= 'directory' then
			module:fail_json({path=path, msg=path .. "already exists as a " .. prev_state})
		end

		changed = File.set_fs_attributes_if_different(module, params, changed, diff)

		if recurse then
			changed = changed or recursive_set_attributes(module, params['path'], follow, params)
		end

		module:exit_json({path=path, changed=changed, diff=diff, msg="Dummy"})

	elseif state == 'link' or state == 'hard' then
		local relpath
		if File.isdir(path) and not File.islnk(path) then
			relpath = path
		else
			relpath = File.dirname(path)
		end

		local absrc = File.join(relpath, {src})
		if not File.exists(absrc) and not force then
			module:fail_json({path=path, src=src, msg='src file does not exist, use "force=yes" if you really want to create the link ' .. absrc})
		end

		if state == 'hard' then
			if not File.isabs(src) then
				module:fail_json({msg="absolute paths are required"})
			end
		elseif pref_state == 'directory' then
			if not force then
				module:fail_json({path=path, msg="refusing to convert between " .. prev_state .. " and " .. state .. " for " .. path})
			else
				local lsdir = File.listdir(path)
				if lsdir and #lsdir > 0 then
					-- refuse to replace a directory that has files in it
					module:fail_json({path=path, msg="the directory " .. path .. " is not empty, refusing to convert it"})
				end
			end
		elseif (prev_state == "file" or prev_state == "hard") and not force then
			module:fail_json({path=path, msg="refusing to convert between " .. prev_state .. " and " .. state .. " for " .. path})
		end

		if prev_state == 'absent' then
			changed = true
		elseif prev_state == 'link' then
			local old_src = File.readlink(path)
			if old_src ~= src then
				changed = true
			end
		elseif prev_state == 'hard' then
			if not (state == 'hard' and File.stat(path)['st_ino'] == File.stat(src)['st_ino']) then
				changed = true
				if not force then
					module:fail_json({dest=path, src=src, msg='Cannot link, different hard link exists at destination'})
				end
			end
		elseif prev_state == 'file' or prev_state == 'directory' then
			changed = true
			if not force then
				module:fail_json({dest=path, src=src, msg='Cannot link, ' .. prev_state .. ' exists at destination'})
			end
		else
			module:fail_json({dest=path, src=src, msg='unexpected position reached'})
		end

		if changed and not module:check_mode() then
			if prev_state ~= absent then
				-- try to replace automically
				local tmppath = string.format("%s/.%d.%d.tmp", File.dirname(path), unistd.getpid(), time.time())

				local status, errstr, errno
				if prev_state == 'directory' and (state == 'hard' or state == 'link')then
					status, errstr, errno = File.rmdir(path)
				end
				if state == 'hard' then
					status, errstr, errno = File.link(src, tmppath)
				else
					status, errstr, errno = File.symlink(src, tmppath)
				end
				if status then
					status, errstr, errno = File.rename(tmppath, path)
				end
				if not status then
					if File.exists(tmppath) then
						File.unlink(tmppath)
					end
					module:fail_json({path=path, msg='Error while replacing ' .. errstr})
				end
			else
				local status, errstr, errno
				if state == 'hard' then
					status, errstr, errno = File.link(src, path)
				else
					status, errstr, errno = File.symlink(src, path)
				end
				if not status then
					module:fail_json({path=path, msg='Error while linking: ' .. errstr})
				end
			end
		end

		if module:check_mode() and not File.exists(path) then
			module:exit_json({dest=path, src=src, msg="dummy", changed=changed, diff=diff})
		end

		changed = File.set_fs_attributes_if_different(module, params, changed, diff)
		module:exit_json({dest=path, src=src, msg="dummy", changed=changed, diff=diff})

	elseif state == 'touch' then
		if not module:check_mode() then
			local status, errmsg
			if prev_state == 'absent' then
				status, errmsg = File.touch(path)
				if not status then
					module:fail_json({path=path, msg='Error, could not touch target: ' .. errmsg})
				end
			elseif prev_state == 'file' or prev_state == 'directory' or prev_state == 'hard' then
				status, errmsg = File.utime(path)
				if not status then
					module:fail_json({path=path, msg='Error while touching existing target: ' .. errmsg})
				end
			else
				module:fail_json({msg='Cannot touch other than files, directories, and hardlinks (' .. path .. " is " .. prev_state .. ")"})
			end

			-- FIXME: SORRY, we can't replicate the catching of SystemExit as far as I know...
			--        so we _may_ leak a file
			File.set_fs_attributes_if_different(module, params, true, diff)
		end

		module:exit_json({dest=path, changed=true, diff=diff, msg="dummy"})
	end

	module.fail_json({path=path, msg='unexpected position reached'})
end

main(arg)
