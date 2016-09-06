local FileUtil = {}

local unistd  = require("posix.unistd")
local stat    = require("posix.sys.stat")
local stdlib  = require("posix.stdlib")
local libgen  = require("posix.libgen")
local pwd     = require("posix.pwd")
local grp     = require("posix.grp")
local os      = require("os")
local bm      = require("BinDecHex")
local perrno  = require("posix.errno")
local utime   = require("posix.utime")
local stdio   = require("posix.stdio")
local dirent  = require("posix.dirent")

FileUtil.__index = FileUtil

function FileUtil.md5(module, path)
	local command = string.format("md5sum %q", path)
	local res, out, err = module:run_command(command)

	if res ~= 0 then
		module:fail_json({msg="Failed to determine the md5sum for " .. path, error=err})
	end

	local md5sum = string.match(out, "^[^%s\n]+")

	return md5sum
end

function FileUtil.sha1(module, path)
	local command = string.format("sha1sum %q", path)
	local res, out, err = module:run_command(command)

	if res ~= 0 then
		module:fail_json({msg="Failed to determine the sha1sum for " .. path, error=err})
	end

	local sha1sum = string.match(out, "^[^%s\n]+")

	return sha1sum
end

function FileUtil.expanduser(path)
	if path == nil then
		return nil
	end
	local home = os.getenv("HOME")

	return string.gsub(path, "^~", home)
end

function FileUtil.lexists(path)
	local status, errstr, errno = unistd.access(path, "f")

	return 0 == status, errstr, errno
end

function FileUtil.exists(path)
	local status, errstr, errno = unistd.access(path, "f")

	return 0 == status, errstr, errno
end

function FileUtil.readable(path)
	local status, errstr, errno = unistd.access(path, "r")

	return 0 == status, errstr, errno
end

function FileUtil.writeable(path)
	local status, errstr, errno = unistd.access(path, "w")

	return 0 == status, errstr, errno
end

function FileUtil.isdir(path)
	local pstat = stat.stat(path)

	if pstat then
		return 0 ~= stat.S_ISDIR(pstat['st_mode'])
	else
		return false
	end
end

function FileUtil.islnk(path)
	local pstat = stat.lstat(path)

	if pstat then
		return 0 ~= stat.S_ISLNK(pstat['st_mode'])
	else
		return false
	end
end

function FileUtil.stat(path)
	return stat.stat(path)
end

function FileUtil.lstat(path)
	return stat.lstat(path)
end

function FileUtil.realpath(path)
	return stdlib.realpath(path)
end

function FileUtil.readlink(path)
	return unistd.readlink(path)
end

function FileUtil.basename(path)
	return libgen.basename(path)
end

function FileUtil.dirname(path)
	return libgen.dirname(path)
end

function FileUtil.rmtree(path, opts)
	local args = "-r"

	if opts['ignore_errors'] then
		args = args .. "f"
	end

	local cmd = string.format("rm %s %q", args, path)

	local rc = nil
	if 5.1 < get_version() then
		_, _, rc = os.execute(cmd)
	else
		rc       = os.execute(cmd)
	end

	return rc ~= 0
end

function FileUtil.unlink(path)
	local status, errstr, errno = unistd.unlink(path)

	return 0 == status, errstr, errno
end

function FileUtil.get_user_and_group(path)
	local stat = FileUtil.stat(path)
	if stat then
		return stat['st_uid'], stat['st_gid']
	else
		return nil, nil
	end
end

function FileUtil.parse_owner(owner)
	local uid = tonumber(owner)
	if (uid == nil) then
		local pwnam = pwd.getpwnam(owner)
		if pwnam ~= nil then
			uid = pwnam['pw_uid']
		end
	end
	return uid
end

function FileUtil.parse_group(group)
	local gid = tonumber(group)
	if (gid == nil) then
		local grnam = grp.getgrnam(group)
		if grnam ~= nil then
			gid = grnam['gr_gid']
		end
	end
	return gid
end

function FileUtil.lchown(path, uid, gid)
	local ret, errstr, errno
	-- lchown is only present in luaposix since 30.07.2016
	if unistd['lchown'] then
		ret, errstr, errno = unistd.lchown(path, uid, gid)
	else
		ret, errstr, errno = unistd.chown(path, uid, gid)
	end
	return ret == 0, errstr, errno
end

function FileUtil.set_owner_if_different(module, path, owner, changed, diff)
	path = FileUtil.expanduser(path)
	if owner == nil then
		return changed
	end
	local orig_uid, orig_gid = FileUtil.get_user_and_group(path)
	local uid = FileUtil.parse_owner(owner)
	if nil == uid then
		module:fail_json({path=path, msg='chown failed: failed to look up user ' .. tostring(owner)})
	end
	if orig_uid ~= uid then
		if nil ~= diff then
			if nil == diff['before'] then
				diff['before'] = {}
			end
			diff['before']['owner'] = orig_uid
			if nil == diff['after'] then
				diff['after'] = {}
			end
			diff['after']['owner'] = uid
		end
	
		if module:check_mode() then
			return true
		end
		-- FIXME: sorry if there is no chown we fail the sematic slightly... but i don't care
		if not FileUtil.lchown(path, uid, -1) then
			module:fail_json({path=path, msg='chown failed'})
		end
		changed = true
	end
	return changed
end

function FileUtil.set_group_if_different(module, path, group, changed, diff)
	path = FileUtil.expanduser(path)
	if group == nil then
		return changed
	end
	local orig_uid, orig_gid = FileUtil.get_user_and_group(path)
	local gid = FileUtil.parse_group(group)
	if nil == gid then
		module:fail_json({path=path, msg='chgrp failed: failed to look up group ' .. tostring(group)})
	end
	if orig_gid ~= gid then
		if nil ~= diff then
			if nil == diff['before'] then
				diff['before'] = {}
			end
			diff['before']['group'] = orig_gid
			if nil == diff['after'] then
				diff['after'] = {}
			end
			diff['after']['group'] = gid
		end
	
		if module:check_mode() then
			return true
		end
		-- FIXME: sorry if there is no chown we fail the sematic slightly... but i don't care
		if not FileUtil.lchown(path, -1, gid) then
			module:fail_json({path=path, msg='chgrp failed'})
		end
		changed = true
	end
	return changed
end

local function tohex(int)
	return bm.Dec2Hex(string.format("%d", int))
end

function FileUtil.S_IMODE(mode)
	-- man 2 stat
	-- "... and the least significant 9 bits (0777) as the file permission bits"
	return tonumber(bm.Hex2Dec(bm.BMAnd(tohex(mode), tohex(0x1ff))))
end

function FileUtil.lchmod(path, mode)
	if not FileUtil.islnk(path) then
		local ret, errstr, errno = stat.chmod(path, mode)
		return ret == 0, errstr, errno
	end
	return true, nil, nil
end

function FileUtil.set_mode_if_different(module, path, mode, changed, diff)
	path = FileUtil.expanduser(path)
	local path_stat = FileUtil.lstat(path)

	if mode == nil then
		return changed
	end

	if type(mode) ~= "number" then
		mode = tonumber(mode, 8)
		if nil == mode then
			module:fail_json({path=path, msg="mode must be in octal form (currently symbolic form is not supported, sorry)"})
		end
	end
	if mode ~= FileUtil.S_IMODE(mode) then
		-- prevent mode from having extra info or being invald long number
		module:fail_json({path=path, msg="Invalid mode supplied, only permission info is allowed", details=mode})
	end

	local prev_mode = FileUtil.S_IMODE(path_stat['st_mode'])

	if prev_mode ~= mode then
		if nil ~= diff then
			if nil == diff['before'] then
				diff['before'] = {}
			end
			diff['before']['mode'] = string.format("%o", prev_mode)
			if nil == diff['after'] then
				diff['after'] = {}
			end
			diff['after']['mode'] = string.format("%o", mode)
		end

		if module:check_mode() then
			return true
		end

		local res, errstr, errno = FileUtil.lchmod(path, mode)
		if not res then
			if errno ~= perrno['EPERM'] and errno ~= perrno['ELOOP'] then
				module:fail_json({path=path, msg='chmod failed', details=errstr})
			end
		end

		path_stat = FileUtil.lstat(path)
		local new_mode = FileUtil.S_IMODE(path_stat['st_mode'])
		
		if new_mode ~= prev_mode then
			changed = true
		end
	end
	return changed
end

function FileUtil.set_fs_attributes_if_different(module, file_args, changed, diff)
	changed = FileUtil.set_owner_if_different(module, file_args['path'], file_args['owner'], changed, diff)
	changed = FileUtil.set_group_if_different(module, file_args['path'], file_args['group'], changed, diff)
	changed = FileUtil.set_mode_if_different(module, file_args['path'], file_args['mode'], changed, diff)
	return changed
end

function FileUtil.isabs(path)
	return 1 == string.find(path, "/")
end

function FileUtil.mkdir(path)
	local status, errstr, errno = stat.mkdir(path)
	return 0 == status, errstr, errno
end

function FileUtil.walk(path, follow)
	local entries = {}
	local stack   = {path}
	local i = 1
	while i <= #stack do
		local cur = stack[i]
		
		local ok, dir = pcall(dirent.dir, cur)

		local entry = { root=cur }
		local dirs = {}
		local files = {}
		if ok and dir ~= nil then
			for _, entry in ipairs(dir) do
				if "." ~= entry and ".." ~= entry then
					local child = cur .. "/" .. entry
					if follow and FileUtil.islnk(child) then
						local dst = FileUtil.realpath(child)
						dirs[#dirs + 1]   = entry
						stack[#stack + 1] = dst
					elseif FileUtil.isdir(child) then
						dirs[#dirs + 1]   = entry
						stack[#stack + 1] = child
					else
						files[#files + 1] = entry
					end
				end
			end
		end
		entry['dirs']  = dirs
		entry['files'] = files
		entries[#entries + 1] = entry
		i = i + 1
	end

	return entries
end

function FileUtil.listdir(path)
	local ok, dir = pcall(dirent.dir, path)
	if not ok then
		return nil
	end

	local entries = {}

	for _, k in ipairs(dir) do
		if k ~= "." and k ~= ".."  then
			entries[#entries + 1] = k
		end
	end

	return entries
end

function FileUtil.rmdir(path)
	local status, errstr, errno = unistd.rmdir(path)

	return 0 == status, errstr, errno
end

function FileUtil.link(target, link)
	local status, errstr, errno = unistd.link(target, link, false)

	return 0 == status, errstr, errno
end

function FileUtil.symlink(target, link)
	local status, errstr, errno = unistd.link(target, link, true)

	return 0 == status, errstr, errno
end

function FileUtil.unlink(path)
	local status, errstr, errno = unistd.unlink(path)

	return 0 == status, errstr, errno
end

function FileUtil.touch(path)
	local file, errmsg = io.open(path, "w")
	if file ~= nil then
		io.close(file)
	end
	return file ~= nil, errmsg
end

function FileUtil.utime(path)
	local status, errstr, errno = utime.utime(path)

	return 0 == status, errstr, errno
end

function FileUtil.join(path, paths)
	for _, segment in ipairs(paths) do
		if segment ~= nil then
			if FileUtil.isabs(segment) then
				path = segment
			else
				path = path .. "/" .. segment
			end
		end
	end

	return path
end

function FileUtil.rename(oldpath, newpath)
	local status, errstr, errno
	if nil ~= stdio['rename'] then
		status, errstr, errno = stdio.rename(oldpath, newpath)
		status = status == 0
	else
		status, errstr, errno = os.rename(oldpath, newpath)
	end

	return status, errstr, errno
end

function FileUtil.split(path)
	local tail = FileUtil.basename(path)
	local head = FileUtil.dirname(path)
	return head, tail
end

function FileUtil.split_pre_existing_dir(dirname)
	-- Return the first pre-existing directory and a list of the new directories that will be created
	local head, tail = FileUtil.split(dirname)

	local pre_existing_dir, new_directory_list
	if not FileUtil.exists(head) then
		pre_existing_dir, new_directory_list = FileUtil.split_pre_existing_dir(head)
	else
		return head, {tail}
	end
	new_directory_list[#new_directory_list + 1] = tail
	return pre_existing_dir, new_directory_list
end

function FileUtil.mkdirs(path)
	local exists, new = FileUtil.split_pre_existing_dir(path)

	for _, seg in ipairs(new) do
		exists = exists .. "/" .. seg
		local res, errstr, errno = FileUtil.mkdir(exists)
		if not res then
			return res, errstr, errno
		end
	end
	return true
end

function FileUtil.mkstemp(pattern)
	local fd, path = stdlib.mkstemp(pattern)
	if -1 ~= fd and type(fd) == "number" then
		unistd.close(fd)
		return path
	else
		return nil, path -- path is a errmsg in this case
	end
end

return FileUtil
