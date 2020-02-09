#!/usr/bin/lua

local Ansible = require("ansible")
local File    = require("fileutils")
local stat    = require("posix.sys.stat")
local errno   = require("posix.errno")
local bm      = require("BinDecHex")
local stdlib  = require("posix.stdlib")
local unistd  = require("posix.unistd")
local pwd     = require("posix.pwd")
local grp     = require("posix.grp")

local function tohex(int)
	return bm.Dec2Hex(string.format("%d", int))
end

local function S_IMODE(mode)
	-- man 2 stat
	-- "... and the least significant 9 bits (0777) as the file permission bits"
	return tonumber(bm.Hex2Dec(bm.BMAnd(tohex(mode), tohex(0x1ff))))
end

local function boolmask(mode, mask)
	local masked = tonumber(bm.Hex2Dec(bm.BMAnd(tohex(mode), tohex(mask))))

	if 0 == masked then
		return false
	else
		return true
	end
end

function main(arg)
	local module = Ansible.new(
		{ path    = { required=true, type='path' }
		, follow  = { default=false, type='bool' }
		, get_md5 = { default=true, type='bool'}
		, get_checksum = { default=true, type='bool' }
		, checksum_algorithm = { default='sha1', type='str', choices={'sha1'}, aliases={'checksum_algo', 'checksum'}}
		}
	)

	module:parse(arg[1])

	local p = module:get_params()

	local path               = p['path']
	local follow             = p['follow']
	local get_md5            = p['get_md5']
	local get_checksum       = p['get_checksum'] 
	local checksum_algorithm = p['checksum_algorithm']

	local st, err, rc
	if follow then
		st, err, rc = stat.stat(path)
	else
		st, err, rc = stat.lstat(path)
	end

	if not st then
		if rc == errno.ENOENT then
			d = { exists=false }
			module:exit_json({msg="No such file exists", changed=false, stat=d})
		end

		module:fail_json({msg=err})
	end

	mode = st['st_mode']

	-- back to ansible
	d = {
		  exists = true
		, path   = path
		, mode   = string.format("%04o", S_IMODE(mode))
		, isdir  = stat.S_ISDIR(mode)
		, ischr  = stat.S_ISCHR(mode)
		, isblk  = stat.S_ISBLK(mode)
		, isreg  = stat.S_ISREG(mode)
		, isfifo = stat.S_ISFIFO(mode)
		, islnk  = stat.S_ISLNK(mode)
		, issock = stat.S_ISSOCK(mode)
		, uid    = st['st_uid']
		, gid    = st['st_gid']
		, size   = st['st_size']
		, inode  = st['st_ino']
		, dev    = st['st_dev']
		, nlink  = st['st_nlink']
		, atime  = st['st_atime']
		, mtime  = st['st_mtime']
		, ctime  = st['ctime']
		, wusr   = boolmask(mode, stat.S_IWUSR)
		, rusr   = boolmask(mode, stat.S_IRUSR)
		, xusr   = boolmask(mode, stat.S_IXUSR)
		, wgrp   = boolmask(mode, stat.S_IWGRP)
		, rgrp   = boolmask(mode, stat.S_IRGRP)
		, xgrp   = boolmask(mode, stat.S_IXGRP)
		, woth   = boolmask(mode, stat.S_IWOTH)
		, roth   = boolmask(mode, stat.S_IROTH)
		, xoth   = boolmask(mode, stat.S_IXOTH)
		, isuid  = boolmask(mode, stat.S_ISUID)
		, isgid  = boolmask(mode, stat.S_ISGID)
	}

	if 0 ~= d['islnk'] then
		d['lnk_source'] = stdlib.realpath(path)
	end

	if 0 ~= d['isreg'] and get_md5 and 0 == unistd.access(path, "r") then
		d['md5'] = File.md5(module, path)
	end

	if 0 ~= d['isreg'] and get_checksum and 0 == unistd.access(path, "r") then
		local chksums = { sha1=File.sha1 }
		d['checksum'] = chksums[p['checksum_algorithm']](module, path)
	end

	local pw = pwd.getpwuid(st['st_uid'])
	d['pw_name'] = pw['pw_name']

	local grp_info = grp.getgrgid(st['st_gid'])
	d['gr_name'] = grp_info['gr_name']

	d['mime_type'] = 'unknown'
	d['charset']   = 'unknown'

	module:exit_json({msg="Stat successful", changed=false, stat=d})
end

main(arg)
