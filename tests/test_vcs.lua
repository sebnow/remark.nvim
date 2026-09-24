local vcs = require("remark.vcs")

-- Bounded so a wedged git/jj process fails this test rather than hanging CI.
local function run(cmd, cwd)
	return vim.system(cmd, { cwd = cwd, text = true }):wait(5000)
end

local function commit_id(dir, rev)
	return vim.trim(run({ "jj", "log", "-r", rev, "--no-graph", "-T", "commit_id" }, dir).stdout)
end

local T = MiniTest.new_set()

T["detect() caches per directory, avoiding repeated subprocess spawns"] = function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")

	local calls = 0
	local orig_system = vim.system
	vim.system = function(cmd, opts)
		calls = calls + 1
		return orig_system(cmd, opts)
	end

	vcs.detect(dir)
	local after_first = calls
	vcs.detect(dir)
	local after_second = calls

	vim.system = orig_system
	MiniTest.expect.equality(after_first, after_second)
end

T["run() passes an explicit timeout to :wait() so a hung git/jj process can't block forever"] = function()
	-- A directory detect() hasn't seen before, so caching can't turn this
	-- into a pure cache hit that never spawns a process to observe.
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")

	local observed_timeout
	local orig_system = vim.system
	vim.system = function(cmd, opts)
		local obj = orig_system(cmd, opts)
		local orig_wait = obj.wait
		obj.wait = function(self, timeout)
			observed_timeout = timeout
			return orig_wait(self, timeout)
		end
		return obj
	end

	vcs.detect(dir)
	vim.system = orig_system

	MiniTest.expect.equality(type(observed_timeout), "number")
	MiniTest.expect.equality(observed_timeout > 0, true)
end

T["detect() falls back to git when jj is not installed"] = function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	run({ "git", "init", "-q" }, dir)
	-- A PATH holding only git, as on a machine without jujutsu.
	local bin = vim.fn.tempname()
	vim.fn.mkdir(bin, "p")
	vim.uv.fs_symlink(vim.fn.exepath("git"), bin .. "/git")
	local orig_path = vim.env.PATH
	vim.env.PATH = bin

	local ok, repo = pcall(vcs.detect, dir)
	vim.env.PATH = orig_path

	MiniTest.expect.equality(ok, true)
	MiniTest.expect.equality(repo and repo.vcs, "git")
end

-- Commits one file in a fresh jj repo, then a change to it; returns the repo,
-- the file's path, and the two commit ids.
local function jj_file_change(name)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	run({ "jj", "git", "init" }, dir)

	-- snapshot.auto-track can be disabled in the user's jj config, so
	-- this repo's new file needs explicit tracking regardless of that setting.
	local path = dir .. "/" .. name
	local f = assert(io.open(path, "w"))
	f:write("a")
	f:close()
	run({ "jj", "file", "track", "--", 'root-file:"' .. name .. '"' }, dir)
	run({ "jj", "commit", "-m", "first" }, dir)
	local from = commit_id(dir, "@-")

	f = assert(io.open(path, "w"))
	f:write("b")
	f:close()
	run({ "jj", "commit", "-m", "second" }, dir)
	return { vcs = "jj", root = dir }, path, from, commit_id(dir, "@-")
end

T["changed() detects a change to a jj-tracked path starting with a dash"] = function()
	local repo, path, from, to = jj_file_change("-weird.lua")

	MiniTest.expect.equality(vcs.changed(repo, from, to, path), true)
end

T["changed() detects a change to a jj-tracked path holding glob characters"] = function()
	local repo, path, from, to = jj_file_change("a[b].lua")

	MiniTest.expect.equality(vcs.changed(repo, from, to, path), true)
end

return T
