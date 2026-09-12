local session = require("remark.session")

-- Isolate the registry file per test case; XDG_STATE_HOME drives
-- vim.fn.stdpath("state"), which the registry lives under (ADR 0008).
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			vim.env.XDG_STATE_HOME = vim.fn.tempname()
		end,
	},
})

local function registry_path()
	return vim.fn.stdpath("state") .. "/remark.nvim/sessions.json"
end

local function read_registry()
	return vim.json.decode(table.concat(vim.fn.readfile(registry_path()), "\n"))
end

T["register() writes serverAddr and logPath keyed by repo root"] = function()
	local addr = session.register("/repo/a", "/repo/a/.remark-state/log.ndjson")
	MiniTest.expect.equality(type(addr) == "string" and addr ~= "", true)

	local entry = read_registry()["/repo/a"]
	MiniTest.expect.equality(entry.serverAddr, addr)
	MiniTest.expect.equality(entry.logPath, "/repo/a/.remark-state/log.ndjson")
end

T["register() reuses the existing server address"] = function()
	local existing = vim.v.servername
	MiniTest.expect.equality(existing ~= "", true)

	local addr = session.register("/repo/reuse", "/repo/reuse/log.ndjson")
	MiniTest.expect.equality(addr, existing)
end

T["a second register() for the same repo overwrites the prior entry"] = function()
	session.register("/repo/a", "/repo/a/old-log.ndjson")
	session.register("/repo/a", "/repo/a/new-log.ndjson")

	local entry = read_registry()["/repo/a"]
	MiniTest.expect.equality(entry.logPath, "/repo/a/new-log.ndjson")
end

T["deregister() removes only its own entry"] = function()
	session.register("/repo/a", "/repo/a/log.ndjson")
	session.register("/repo/b", "/repo/b/log.ndjson")

	session.deregister("/repo/a")

	local registry = read_registry()
	MiniTest.expect.equality(registry["/repo/a"], nil)
	MiniTest.expect.equality(registry["/repo/b"].logPath, "/repo/b/log.ndjson")
end

T["deregister() on a missing entry is a no-op"] = function()
	MiniTest.expect.no_error(function()
		session.deregister("/repo/never-registered")
	end)
end

return T
