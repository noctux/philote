#!/usr/bin/lua

local Ansible = require("ansible")
local File    = require("fileutils")

local function join(list, sep)
	local cur = ""
	for i, v in ipairs(list) do
		if i ~= 1 then
			cur = string.format("%s%s%s", cur, sep, v)
		else
			cur = v
		end
	end
	return cur
end

function write_changes(module, lines, dest)
	-- FIXME: we do not support validate, sorry
	module:unslurp(dest, join(lines, "\n") .. "\n")
end

function check_file_attrs(module, changed, message, diff)
	file_args = module:get_params()
	if File.set_fs_attributes_if_different(module, file_args, changed, diff) then
		if changed then
			message = message .. " and "
		end
		changed = true
		message = message .. "ownership or perms changed"
	end

	return message, changed
end

local function splitlines(content)
	local lines = {}
	for line in string.gmatch(content, "[^\n]+") do
		lines[#lines + 1] = line
	end
	return lines
end

local function append(t1, t2)
	for k,v in ipairs(t2) do
		t1[#t1 + 1] = v
	end
	return t1
end


local function rstrip(str, chars)
	return string.gsub(str, string.format("[%s]+$", chars), "")
end

local function filter(matcher, list)
	local tmp = {}
	for i,v in ipairs(list) do
		if matcher(v) then
			tmp[#tmp + 1] = v
		end
	end
	return tmp
end

function present(module, dest, regexp, line, insertafter, insertbefore, create, backup, backrefs)
	diff = {before="", after="", before_header=dest .. " (content)", after_header=dest .. " (content)"}

	local lines
	if not File.exists(dest) then
		if not create then
			module:fail_json({rc=257, msg='Destination ' .. dest .. ' does not exist!'})
		end
		local destpath = File.dirname(dest)
		if not File.exists(destpath) and not module:check_mode() then
			local status, errstr = File.mkdirs(destpath)
			if not status then
				module:fail_json({msg="Failed to create path components for " .. destpath .. ": " .. errstr})
			end
		end
		lines = {}
	else
		lines = splitlines(module:slurp(dest))
	end

	if module._diff then
		diff['before'] = join(lines, "\n")
	end
	
	local mre = regexp
	
	local insre = nil
	if insertafter ~= nil and insertafter ~= 'BOF' and insertafter ~= 'EOF' then
		insre = insertafter
	elseif insertbefore ~= nil and insertbefore ~= 'BOF' then
		insre = insertbefore
	end


	-- matchno is the line num where the regexp has been found
	-- borano  is the line num where the insertafter/insertbefore has been found
	local matchno, borano = -1, -1
	local m = nil
	for lineno, cur_line in ipairs(lines) do
		if regexp ~= nil then
			-- FIXME: lua patterns are not regexes
			match_found = string.match(cur_line, mre)
		else
			match_found = line == rstrip(cur_line, '\r\n')
		end
		if match_found then
			matchno = lineno
			m = cur_line
		elseif insre ~= nil and string.match(cur_line, insre) then
			if insertafter then
				-- + 1 for the next line
				borano = lineno + 1
			end
			if insertbefore then
				-- + 1 for the previous line
				borano = lineno
			end
		end
	end

	local msg = ''
	local changed = false

	-- Regexp matched a line in the file
	if matchno ~= -1 then
		local new_line
		if backrefs then
			new_line = string.gsub(m, mre, line)
		else
			-- don't do backref expansion if not asked
			new_line = line
		end

		new_line = rstrip(new_line, '\r\n')
	
		if lines[matchno] ~= new_line then
			lines[matchno] = new_line
			msg = 'line replaced'
			changed = true
		end
	elseif backrefs then
		-- Do absolutely nothing since it's not safe generating the line
		-- without the regexp matching to populate the backrefs
	elseif insertbefore == 'BOF' or insertafter=='BOF' then
		local tmp = { line }
		lines = append(tmp, lines)
		msg = 'line added'
		changed = true
	-- Add it to the end of the file if requested or
	-- if insertafter/insertbefore didn't match anything
	-- (so default behaviour is to add at the end)
	elseif insertafter == 'EOF' or borano == -1 then
		lines[#lines + 1] = line
		msg = 'line added'
		changed = true
	-- insert* matched, but not the regexp
	else
		local tmp = {}
		for i,v in ipairs(lines) do
			if i == borano then
				tmp[#tmp + 1] = line
			end
			tmp[#tmp + 1] = v
		end
	end

	if module._diff then
		diff['after'] = join(lines, "\n")
	end

	local backupdest = ""
	if changed and not module:check_mode() then
		if backup and File.exists(dest) then
			backupdest = module:backup_local(dest)
		end
		write_changes(module, lines, dest)
	end

	if module:check_mode() and not File.exists(dest) then
		module:exit_json({changed=changed, msg=msg, backup=backupdest, diff=diff})
	end

	local attr_diff = {}
	msg, changed = check_file_attrs(module, changed, msg, attr_diff)

	attr_diff['before_header'] = dest .. " (file attributes)"
	attr_diff['after_header']  = dest .. " (file attributes)"

	local difflist = {diff, attr_diff}
	module:exit_json({changed=changed, msg=msg, backup=backupdest, diff=difflist})
end

function absent(module, dest, regexp, line, backup)
	if not File.exists(dest) then
		module:exit_json({changed=false, msg="file not present"})
	end

	local msg = ""
	diff = {before='', after='', before_header=dest .. '(content)', after_header=dest .. '(content)'}

	local lines = splitlines(module:slurp(dest))

	if module._diff then
		diff['before'] = join(lines, "\n")
	end

	local cre
	if regexp ~= nil then
		cre = regexp
	end
	found = {}

	local function matcher(cur_line)
		local match_found
		if regexp ~= nil then
			match_found = string.match(cur_line, cre)
		else
			match_found = line == rstrip(cur_line, "\r\n")
		end
		if match_found then
			found[#found + 1] = cur_line
		end

		return not match_found
	end

	lines = filter(matcher, lines)
	changed = #found > 0

	if module._diff then
		diff['after'] = join(lines, "\n")
	end

	backupdest = ""
	if changed and not module:check_mode() then
		if backup then
			backupdest = module:backup_local(dest)
		end
		write_changes(module, lines, dest)
	end

	if changed then
		msg = tostring(#found) .. " line(s) removed"
	end

	local attr_diff={}
	attr_diff['before_header'] = dest .. " (file attributes)"
	attr_diff['after_header']  = dest .. " (file attributes)"

	local difflist = {diff, attr_diff}
	module:exit_json({changed=changed, found=#found, msg=msg, backup=backupdest, diff=difflist})
end

function main(arg)
	local module = Ansible.new({
		line         = { type='str' },
		mode         = { type='str' },
		backup       = { default=false, type='bool' },
		insertbefore = { type='str' },
		insertafter  = { type='str' },
		owner        = { type='str' },
		group        = { type='str' },
		backrefs     = { default=false, type='bool' },
		create       = { default=false, type='bool' },
		path         = { aliases={'name', 'dest', 'destfile'}, type='path', required='true' },
		regexp       = { type='str' },
		state        = { default = "present", choices={"present", "absent"} },
	})

	module:parse(arg[1])

	local p = module:get_params()

	-- Ensure that the dest parameter is valid
	local dest = File.expanduser(p['path'])
	local create = p['create']
	local backup = p['backup']
	local backrefs = p['backrefs']

	if p['insertbefore'] and p['insertafter'] then
		module:fail_json({msg="The options insertbefore and insertafter are mutually exclusive"})
	end

	if File.isdir(dest) then
		module:fail_json({msg="Destination " .. dest .. " is a directory!"})
	end

	if p['state'] == "present" then
		if backrefs and p['regexp'] == nil then
			module:fail_json({msg='regexp= is required wioth backrefs=true'})
		end

		if p['line'] == nil then
			module:fail_json({msg='line= is required with state=present'})
		end

		-- Deal with the insertafter default value manually, to avoid errors
		-- because of the mutually_exclusive mechanism
		local ins_bef, ins_aft = p['insertbefore'], p['insertafter']
		if ins_bef == nil and ins_aft == nil then
			ins_aft = 'EOF'
		end

		local line = p['line']
		present(module, dest, p['regexp'], line, ins_aft, ins_bef, create, backup, backrefs)
	else
		if p['regexp'] == nil and p['line'] == nil then
			module:fail_json({msg='one of line= or regexp= is required with state=absent'})
		end
		absent(module, dest, p['regexp'], p['line'], backup)
	end
end

main(arg)
