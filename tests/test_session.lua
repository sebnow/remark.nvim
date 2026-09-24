local session = require("remark.session")

local T = MiniTest.new_set()

local function read_registry(path)
	return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function tmp_registry_path()
	return vim.fn.tempname() .. "/sessions.json"
end

T["register() writes serverAddr and logPath keyed by repo root, at the given registry_path"] = function()
	local registry_path = tmp_registry_path()

	local addr = session.register("/repo/a", "/repo/a/.remark-state/log.ndjson", registry_path)
	MiniTest.expect.equality(type(addr) == "string" and addr ~= "", true)

	local entry = read_registry(registry_path)["/repo/a"]
	MiniTest.expect.equality(entry.serverAddr, addr)
	MiniTest.expect.equality(entry.logPath, "/repo/a/.remark-state/log.ndjson")
end

T["register() reuses the existing server address"] = function()
	local existing = vim.v.servername
	MiniTest.expect.equality(existing ~= "", true)

	local addr = session.register("/repo/reuse", "/repo/reuse/log.ndjson", tmp_registry_path())
	MiniTest.expect.equality(addr, existing)
end

T["a second register() for the same repo overwrites the prior entry"] = function()
	local registry_path = tmp_registry_path()
	session.register("/repo/a", "/repo/a/old-log.ndjson", registry_path)
	session.register("/repo/a", "/repo/a/new-log.ndjson", registry_path)

	local entry = read_registry(registry_path)["/repo/a"]
	MiniTest.expect.equality(entry.logPath, "/repo/a/new-log.ndjson")
end

T["deregister() removes only its own entry"] = function()
	local registry_path = tmp_registry_path()
	session.register("/repo/a", "/repo/a/log.ndjson", registry_path)
	session.register("/repo/b", "/repo/b/log.ndjson", registry_path)

	session.deregister("/repo/a", registry_path)

	local registry = read_registry(registry_path)
	MiniTest.expect.equality(registry["/repo/a"], nil)
	MiniTest.expect.equality(registry["/repo/b"].logPath, "/repo/b/log.ndjson")
end

T["deregister() leaves an entry another session has since taken over"] = function()
	local registry_path = tmp_registry_path()
	session.register("/repo/a", "/repo/a/log.ndjson", registry_path)
	-- A second session on the same repo registers after this one.
	local registry = read_registry(registry_path)
	registry["/repo/a"] = { serverAddr = "/tmp/other-session.sock", logPath = "/repo/a/log.ndjson" }
	vim.fn.writefile({ vim.json.encode(registry) }, registry_path)

	session.deregister("/repo/a", registry_path)

	MiniTest.expect.equality(read_registry(registry_path)["/repo/a"].serverAddr, "/tmp/other-session.sock")
end

T["deregister() on a missing entry is a no-op"] = function()
	MiniTest.expect.no_error(function()
		session.deregister("/repo/never-registered", tmp_registry_path())
	end)
end

T["register() creates the registry file and its directory as owner-only"] = function()
	local registry_path = tmp_registry_path()

	session.register("/repo/a", "/repo/a/log.ndjson", registry_path)

	MiniTest.expect.equality(vim.fn.getfperm(registry_path), "rw-------")
	MiniTest.expect.equality(vim.fn.getfperm(vim.fn.fnamemodify(registry_path, ":h")), "rwx------")
end

T["register()/deregister() fall back to a path under stdpath(state) when none is given"] = function()
	vim.env.XDG_STATE_HOME = vim.fn.tempname()
	local default_path = vim.fn.stdpath("state") .. "/remark.nvim/sessions.json"

	session.register("/repo/default", "/repo/default/log.ndjson")

	local entry = read_registry(default_path)["/repo/default"]
	MiniTest.expect.equality(entry.logPath, "/repo/default/log.ndjson")
end

return T
