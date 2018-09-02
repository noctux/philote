local Ansible = {}

local io   = require("io")
local json = require("dkjson")
local ubus = require("ubus")

Ansible.__index = Ansible

local json_arguments = [===[<<INCLUDE_ANSIBLE_MODULE_JSON_ARGS>>]===]

function Ansible.new(spec) 
	local self = setmetatable({}, Ansible)
	self.spec = spec
	for k,v in pairs(spec) do
		v['name'] = k
	end
	self.params = nil
	return self
end

local function split(str, delimiter)
	local toks = {}

	for tok in string.gmatch(str, "[^".. delimiter .. "]+") do
		toks[#toks + 1] = tok
	end

	return toks
end

local function append(t1, t2)
	for k,v in ipairs(t2) do
		t1[#t1 + 1] = v
	end
	return t1
end

function Ansible.contains(needle, haystack)
	for _,v in pairs(haystack) do
		if needle == v then
			return true
		end
	end

	return false
end

local function findspec(name, spec)
	if spec[name] then
		return spec[name]
	end

	-- check whether an alias exists
	for k,v in pairs(spec) do
		if type(v) == "table" and v['aliases'] then
			if Ansible.contains(name, v['aliases']) then
				return v
			end
		end
	end

	return nil
end

local function starts_with(str, start)
	return str:sub(1, #start) == start
end

local function extract_internal_ansible_params(params)
	local copy = {}
	for k,v in pairs(params) do
		if starts_with(k, "_ansible") then
			copy[k] = v
		end
	end
	return copy
end

local function canonicalize(params, spec)
	local copy = {}
	for k,v in pairs(params) do
		local desc = findspec(k, spec)
		if not desc then
			-- ignore _ansible parameters
			if 1 ~= string.find(k, "_ansible") then
				return nil, "no such parameter " .. k
			end
		else
			if copy[desc['name']] then
				return nil, "duplicate parameter " .. desc['name']
			end
			copy[desc['name']] = v
		end
	end

	params = copy

	return copy
end

function Ansible:slurp(path)
	local f, err = io.open(path, "r")
	if f == nil then
		Ansible.fail_json({msg="failed to open file " .. path .. ": " .. err})
	end
	local content = f:read("*a")
	if content == nil then
		self:fail_json({msg="read from file " .. path .. "failed"})
	end
	f:close()
	return content
end

function Ansible:unslurp(path, content)
	local f, err = io.open(path, "w+")
	if f == nil then
		Ansible.fail_json({msg="failed to open file " .. path .. ": " .. err})
	end
	
	local res = f:write(content)

	if not res then
		self:fail_json({msg="read from file " .. path .. "failed"})
	end
	f:close()
	return res
end

local function parse_dict_from_string(str)
	if 1 == string.find(str, "{") then
		-- assume json, try to decode it
		local dict, pos, err = json.decode(str)
		if not err then
			return dict
		end
	elseif string.find(str, "=") then
		fields = {}
		field_buffer = ""
		in_quote = nil
		in_escape = false
		for c in str:gmatch(".") do
			if in_escape then
				field_buffer = field_buffer .. c
				in_escape = false
			elseif c == '\\' then
				in_escape = true
			elseif not in_quote and ('\'' == c or '"' == c) then
				in_quote = c
			elseif in_quote and in_quote == c then
				in_quote = nil
			elseif not in_quote and (',' == c or ' ' == c) then
				if string.len(field_buffer) > 0 then
					fields[#fields + 1] = field_buffer
				end
				field_buffer=""
			else
				field_buffer = field_buffer .. c
			end
		end
		-- append the final field
		fields[#fields + 1] = field_buffer

		local dict = {}

		for _,v in ipairs(fields) do
			local key, val = string.match(v, "^([^=]+)=(.*)")

			if key and val then
				dict[key] = val
			end
		end

		return dict
	end

	return nil, str ..  " dictionary requested, could not parse JSON or key=value"
end

local function check_transform_type(variable, ansibletype)
	-- Types: str list dict bool int float path raw jsonarg
	if     "str"     == ansibletype then
		if type(variable) == "string" then
			return variable
		end
	elseif "list"    == ansibletype then
		if type(variable) == "table" then
			return variable
		end

		if type(variable) == "string" then
			return split(variable, ",")
		elseif type(variable) == "number" then
			return {variable}
		end
	elseif "dict"    == ansibletype then
		if type(variable) == "table" then
			return variable
		elseif type(variable) == "string" then
			return parse_dict_from_string(variable)
		end
	elseif "bool"    == ansibletype then
		if "boolean" == type(variable) then
			return variable
		elseif "number" == type(variable) then
			return not (0 == variable)
		elseif "string" == type(variable) then
			local BOOLEANS_TRUE  = {'yes', 'on', '1', 'true', 'True'}
			local BOOLEANS_FALSE = {'no', 'off', '0', 'false', 'False'}

			if Ansible.contains(variable, BOOLEANS_TRUE) then
				return true
			elseif Ansible.contains(variable, BOOLEANS_FALSE) then
				return false
			end
		end
	elseif "int"     == ansibletype or "float"   == ansibletype then
		if type(variable) == "string" then
			local var = tonumber(variable)
			if var then
				return var
			end
		elseif type(variable) == "number" then
			return variable
		end
	elseif "path"    == ansibletype then
		-- A bit basic, i know
		if type(variable) == "string" then
			return variable
		end
	elseif "raw"     == ansibletype then
		return variable
	elseif "jsonarg" == ansibletype then
		if     "table" == type(variable) then
			return variable
		elseif "string" == type(variable) then
			local dict, pos, err = json.decode(variable)
			if not err then
				return dict
			end
		end
	else
		return nil, ansibletype .. " is not a known type"
	end

	return nil, tostring(variable) .. " does not conform to type " .. ansibletype
end

function Ansible:parse(inputfile)
	local params, pos, err = json.decode(json_arguments)

	if err then
		self:fail_json({msg="INTERNAL: Illegal json input received"})
	end

	self.internal_params = extract_internal_ansible_params(params)
	self._diff = self.internal_params['_ansible_diff']

	-- resolve aliases
	params, err = canonicalize(params, self.spec)

	if not params then
		self:fail_json({msg="Err: " .. tostring(err)})
	end

	for k,v in pairs(self.spec) do
		-- setup defaults
		if v['default'] then
			if nil == params[k] then
				params[k] = v['default']
			end
		end

		-- assert requires
		if v['required'] then
			if not params[k] then
				self:fail_json({msg="Required parameter " .. k .. " not provided"})
			end
		end
	end
	
	-- check types/choices
	for k,v in pairs(params) do
		local typedesc = self.spec[k]['type']
		if typedesc then
			local val, err = check_transform_type(v, typedesc)
			if nil ~= val then
				params[k] = val
			else
				self:fail_json({msg="Err: " .. tostring(err)})
			end
		end

		local choices = self.spec[k]['choices']
		if choices then
			if not Ansible.contains(v, choices) then
				self:fail_json({msg=v .. " not a valid choice for " .. k})
			end
		end
	end

	self.params = params

	return params
end

local function file_exists(path)
	local f=io.open(path,"r")
	if f~=nil then
		io.close(f)
		return true
	else
		return false
	end
end

function Ansible:get_bin_path(name, required, candidates)
	if not candidates then
		candidates = {}
	end

	local path = os.getenv("PATH")
	if path then
		candidates = append(candidates, split(path, ":"))
	end

	for _,dir in pairs(candidates) do
		local fpath = dir .. "/" .. name
		if file_exists(fpath) then
			return fpath
		end
	end

	if required then
		self:fail_json({msg="No executable " .. name .. " found in PATH or candidates"})
	end
	
	return nil
end

function Ansible:remove_file(path)
	local rc, err = os.remove(path)
	if nil == rc then
		self:fail_json({msg="Internal, execute: failed to remove file " .. path})
	end
	return rc
end

local function get_version()
	local version = assert(string.match(_VERSION, "Lua (%d+.%d+)"))
	return tonumber(version) -- Aaaah, it hurts to use floating point like this...
end

function Ansible:run_command(command)
	local stdout = os.tmpname()
	local stderr = os.tmpname()

	local cmd = string.format("%s >%q 2>%q", command, stdout, stderr)

	local rc = nil
	if 5.1 < get_version() then
		_, _, rc = os.execute(cmd)
	else
		rc       = os.execute(cmd)
	end

	local out = self:slurp(stdout)
	local err = self:slurp(stderr)
	
	self:remove_file(stdout)
	self:remove_file(stderr)

	return rc, out, err
end

function Ansible:copy(src, dest)
	local command = string.format("cp -f %q %q", src, dest)
	local rc, _,  err = self:run_command(command)

	if rc ~= 0 then
		return false, err
	else
		return true, err
	end
end

function Ansible:move(src, dest)
	local command = string.format("mv -f %q %q", src, dest)
	local rc, _,  err = self:run_command(command)

	if rc ~= 0 then
		return false, err
	else
		return true, err
	end
end

function Ansible:fail_json(kwargs)
	assert(kwargs['msg'])
	kwargs['failed'] = true
	if nil == kwargs['changed'] then
		kwargs['changed'] = false
	end
	if nil == kwargs['invocation'] then
		kwargs['invocations'] = {module_args=self.params}
	end

	io.write(json.encode(kwargs))
	os.exit(1)
end

function Ansible:exit_json(kwargs)
	if nil == kwargs['changed'] then
		kwargs['changed'] = false
	end
	if nil == kwargs['invocation'] then
		kwargs['invocations'] = {module_args=self:get_params()}
	end

	io.write(json.encode(kwargs))
	os.exit(0)
end

function Ansible:get_params()
	return self.params
end

function Ansible:ubus_connect()
	local p = self:get_params()
	local timeout = p['timeout']
	if not timeout then
		timeout = 30
	end
	local socket = p['socket']

	local conn = ubus.connect(socket, timeout)
	if not conn then
		self:fail_json({msg="Failed to connect to ubus"})
	end

	return conn
end

function Ansible:ubus_call(conn, namespace, procedure, arg)
	local res, status = conn:call(namespace, procedure, arg)

	if nil ~= status and 0 ~= status then
		self:fail_json({msg="Ubus call failed", call={namespace=namespace, procedure=procedure, arg=arg, status=status}})
	end

	return res
end

function Ansible:backup_local(file)
	local backupdest

	if file_exits(file) then
		local ext = os.time("%Y-%m-%d@H:%M:%S~")

		backupdest = string.format("%s.%s", file, ext)

		local content = self:slurp(file)
		local res = self:unslurp(backupdest, content)
	end

	return backupdest
end

function Ansible:is_dir(path)
	local f, err, code = io.open(path, "r")

	if nil == f then
		return false, err, code
	end

	local ok, err, code = f:read(1)
	f:close()
	return code == 21, nil, nil
end

function Ansible:check_mode()
	return self.internal_params["_ansible_check_mode"]
end

return Ansible
