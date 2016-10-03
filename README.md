# Philote

Ansible orcherstration for Openwrt - with Lua!

Ansible is build around a collection of modules that get send to the remote
host to execute different tasks or collect information. Those modules are
implemented in python. However on embedded systems such as routers, resources,
in particular flash memory are scarce and a python runtime often not available.

Those modules communicate with the ansible-toolsuite via well defined interfaces
and are executed via ssh. As each module is a standalone program, there is no
dependency whatsoever on the implementation language. There are existing
attempts like [this](https://github.com/lefant/ansible-openwrt) which already
implement a small set of modules as bash-scripts.

However the primary author of this project disagrees with some of the
implementation decisions (e.g. sourcing files with key=value-pairs as a kind of
parsing) and is generally a fan of (even rather limited in luas case) typing. So
this project was born.

As the OpenWrt community seems to have a strange affection for lua, this
repository currently implements the following modules:
- [copy](https://docs.ansible.com/ansible/copy_module.html)
- [file](https://docs.ansible.com/ansible/file_module.html)
- [lineinfile](https://docs.ansible.com/ansible/lineinfile_module.html)
- opkg
- [stat](https://docs.ansible.com/ansible/stat_module.html)
- ubus
- uci

Copy, file, lineinfile, stat and opkg are mostly straightforward ports of the
official python modules included in the Ansible v2.1.1.0 release. However, there
were some simplifications made:
- selinux file attributes are not supported
- validation commands are not supported
- file-operations are not guaranteed to be atomic
- permissions can only be specified in octal mode
- check_mode is only partly implemented

Apart from that, the modules should behave exactly like the upstream modules,
making it possible to use local actions such as
"[template](https://docs.ansible.com/ansible/template_module.html)" which are
built upon those modules.

# Requirements

For building the modules, perl and the
[Data::Compare](http://search.cpan.org/~dcantrell/Data-Compare-1.25/lib/Data/Compare.pm)
library are required.

If you want to use the file related modules (copy, file, lineinfile, stat), the
following opkg packages are required, which are not part of the standard images:
- luaposix
- coreutils-sha1sum

However, as the opkg-module is independent from those packages, you can install
them in your playbook like this:

```yaml
      - name: Installing dependencies for file-related modules
        opkg: pkg=luaposix,coreutils-sha1sum state=present update_cache=yes
```

# Building/Installation

Ansible currently has no notion of libraries used within modules (only limited
support for ansibles own core python libraries is available). For more
information please see
[this issue](https://github.com/ansible/ansible/pull/10274). Therefore all
modules that should be used have to be fatpacked (that is, the module all
referenced libraries have to be packed into one giant lua script). This is done
by the [fatpack.pl](./src/fatpack.pl) script. Usage is like this:

```bash
./src/fatpack.pl --input <module>.lua --output ./library/ --whitelist
io,os,posix.,ubus --truncate
```

To make this process easier, a Makefile is provided that packs all modules in
`./src/` and places the fatpacked variants in `library` for you. Just run `make`
in the projects top directory.

Please note, that this project is currently in **alpha** state. I used it to manage
my personal router (playbook coming soon), but it still might easily lock you
out of your device, eat your hamsters or worse. So please check your playbook
beforehand against a VM (e.g. the one from the openwrt-vagrant project which
can be built from the submodule in `./test/`) or be sure that your router has a
convenient reset/failsafe path.

Apart form the `./library/` folder, you might want to copy the provided `ansible.cfg` as it configures ansible for better interoperability with the dropbear ssh-daemon used by openwrt.

# Documentation

For the following modules, please refer to the upstream documentation
- [copy](https://docs.ansible.com/ansible/copy_module.html)
- [file](https://docs.ansible.com/ansible/file_module.html)
- [lineinfile](https://docs.ansible.com/ansible/lineinfile_module.html)
- [opkg](https://docs.ansible.com/ansible/opkg_module.html)
- [stat](https://docs.ansible.com/ansible/stat_module.html)

## ubus module

As a replacement for then official setup module, information on the openwrt
system can be gatherd via the ubus interface and will automatically be
integrated into the host_facts for reuse in the playbook like this:

```yaml
	ubus: cmd=facts
```

Otherwise, this module is a slim wrapper around the
[ubus rpc-bus](https://wiki.openwrt.org/doc/techref/ubus).

For a list of available ubus-service-providers and their functions, you can
issue a list call. Please note that this call is not really useful in an
automated setting:
```bash
$ ansible openwrt -i hosts -m ubus -a 'cmd=list'
openwrt | SUCCESS => {
    "changed": false,
    "invocations": {
        "module_args": {
            "command": "list"
        }
    }, 
    "msg": "Gathered local signatures",
    "signatures": {
		[...]
        "uci": {
			[...]
			            "get": {
                "config": 3,
                "match": 2,
                "option": 3,
                "section": 3,
                "type": 3,
                "ubus_rpc_session": 3
            },
			[...]
        },
		[...]
    }
}
```

Those signatures can then be used to make Calls via ubus:

```yaml
ubus: cmd=call path=uci method=get message='{"config":"uhttpd", "section":"main", "option":"listen_http"}"'
```

As you can see, the `ubus_rpc_session` parameter is automatically inserted for
you by the module. The ubus return value is returned in the `result` field of the returned object and can be accessed like this:

```yaml
- name: Query http listen ports
  ubus: cmd=call path=uci method=get message='{"config":"uhttpd", "section":"main", "option":"listen_http"}"'
  register: foo

- name: Do something
  baz: param={{ result.value }}
```

## UCI-Module

As most ubus calls will most likely target the
[uci-system](https://wiki.openwrt.org/doc/uci) a dedicated module/ubus-wrapper
for the uci configuration is provided. Basic familiarity with uci is assumed, so
please refer to the upstream [documentation](https://wiki.openwrt.org/doc/uci)
otherwise. Most of the options should map quite naturally to the module
parameters:

A special warning about types: UCI has two types for values internally: `list`
and `option`. The module tries to infer the type by looking for `,` in the
input. If you need to force a singleentry list, please be sure to set the
`forcelist=yes` parameter.

| parameter | required | default | choices                     | comments                                                                                                                                                                                           |
|-----------|----------|---------|-----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| name      | no       |         |                             | Path to the property to change. Syntax is `config.section.option`. _Aliases: path, key_                                                                                                            |
| value     | no       |         |                             | For set: value to set the property to                                                                                                                                                              |
| forcelist | no       | false   | Boolean                     | The module trys to guess the uci config type (list or string) from the supplied value via the existance of `,` in the input. Single entry lists require `forcelist=yes` to be recognized correctly |
| state     | no       | present | present, absent, set, unset | State of the property                                                                                                                                                                              |
| op        | no       |         | configs, commit, revert     | If specified, instead of enforcing a value, either list the available configurations, or execute a commit/revert operation                                                                         |
| reload    | no       |         | Boolean                     | Whether to reload the configuration from disk before executing. _Aliases: reload_configs, reload-configs_                                                                                          |
| autocomit | no       | true    | Boolean                     | Whether to automatically commit the changes made                                                                                                                                                   |
| type      | no       |         |                             | When creating a new section, a configuration-type is required. Aliases: _section-type_                                                                                                             |
| socket    | no       |         |                             | Set a nonstandard path to the ubus socket if necessary                                                                                                                                             |
| timeout   | no       |         |                             | Change the default ubus timeout                                                                                                                                                                    |

Examples:

```yaml
# Set a value
uci: name="system.@system[0].hostname" value="mysuperduperrouter"

# Delete a value
uci: name="system.@system[0].hostname" state=absent

# Revert and commit globally
uci: op=revert
uci: op=commit

# Only commit/revert a single section
uci: path=dropbear op=revert
uci: path=dropbear op=commit

# Create the uhttpd.test section with type uhttp
# and set foo=bar
uci: name=uhttpd.test.foo value=bar type="uhttpd" autocommit=false'

# Remove the uttpd.test section
uci: name=uhttpd.test state="absent" autocommit=true'

# Get a list of all available configuration files
uci: op=configs
```

An more complex example showing the usage of forcelist:

```yaml
  - name: Securing uhttpd - Disable listening on wan
	uci: name={{ item.key }} value={{ uci.state.network.lan.ipaddr }}:{{ item.port }} forcelist=true autocommit=false
	with_items:
		- { key: 'uhttpd.main.listen_http',  port: '80' }
		- { key: 'uhttpd.main.listen_https', port: '443' }
	notify:
		- uci commit
```

# Contributing

Give me all your pullrequests :) If you find a bug in one of the provided modules
(quite possible) or want to contribute a new module, feel free to propose a
pullrequest.
To make development of the modules easier, two libraries are provided. The
ansible library in `./src/ansible.lua` tries to provide a easy starting point
for module development similar to ansibles `ansible.module_utils.basic` library.

It will handle argument parsing for you:

```lua
	local module = Ansible.new({
		name =  { aliases = {"pkg"}, required=true , type='list'},
		state = { default = "present", choices={"present", "installed", "absent", "removed"} },
		force = { default = "", choices={"", "depends", "maintainer", "reinstall", "overwrite", "downgrade", "space", "postinstall", "remove", "checksum", "removal-of-dependent-packages"} } ,
		update_cache = { default = "no", aliases={ "update-cache" }, type='bool' }
	})

	module:parse(arg[1])

	local p = module:get_params()
```

And provides some convenience function such as `get_bin_path`, `run_command`,
`fail_json` and `exit_json`. Currently, those are badly underdocumented, but
the names are mostly selfexplanatory, so just look through the functions in the
file.

```lua
	local opkg_path = module:get_bin_path('echo', true, {'/bin'})
	local rc, out, err = module:run_command(string.format("%s foobar", opkg_path))
	if rc ~= 0 then
		module:fail_json({msg="failed to echo foobar", info={rc=rc, out=out, err=err}})
	else
		module:exit_json({msg="successfully echod foobar", changed=false})
	end
```

Additionally, the `./src/fileutils.lua` module has various wrappers for various
filesystemrelated tasks. Again: Please look up the functions in the sourcefile
and look how they are used in the provided modules.

# License

The libraries and submodules were only included in this repository for
convenience and are available under their own respective licenses:
- [dkjson](http://dkolf.de/src/dkjson-lua.fsl/home) MIT License
- [BinDecHex](http://www.dialectronics.com/Lua/code/BinDecHex.shtml) MIT License
- [openwrt-in-vagrant](https://github.com/lifeeth/openwrt-in-vagrant) MIT License

All other code is available under the terms and conditions of the AGPL3 license.
For more details please see the [LICENSE file](LICENSE).

# Trivia

In Orson Scott Cards marvellous Ender's Game series the term "ansible" refers to
a device for faster than light communication. The philote is the (fictional)
subatomic particle which delivers the actual messages.
