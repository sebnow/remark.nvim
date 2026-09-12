local vcs = require("remark.vcs")

local function run(cmd, cwd)
	return vim.system(cmd, { cwd = cwd, text = true }):wait()
end

local function commit_id(dir, rev)
	return vim.trim(run({ "jj", "log", "-r", rev, "--no-graph", "-T", "commit_id" }, dir).stdout)
end

local T = MiniTest.new_set()

T["changed() detects a change to a jj-tracked path starting with a dash"] = function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	run({ "jj", "git", "init" }, dir)

	-- snapshot.auto-track can be disabled in the user's jj config, so
	-- this repo's new file needs explicit tracking regardless of that setting.
	local path = dir .. "/-weird.lua"
	local f = assert(io.open(path, "w"))
	f:write("a")
	f:close()
	run({ "jj", "file", "track", "--", "-weird.lua" }, dir)
	run({ "jj", "commit", "-m", "first" }, dir)
	local from = commit_id(dir, "@-")

	f = assert(io.open(path, "w"))
	f:write("b")
	f:close()
	run({ "jj", "commit", "-m", "second" }, dir)
	local to = commit_id(dir, "@-")

	local changed = vcs.changed({ vcs = "jj", root = dir }, from, to, path)
	MiniTest.expect.equality(changed, true)
end

return T
