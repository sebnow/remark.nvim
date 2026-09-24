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

local function write(path, lines)
	vim.fn.writefile(lines, path)
end

local ten_lines = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }

-- A fresh repo of the given backend holding one committed file, and a function
-- that commits new content for it and returns the resulting commit id.
local function repo_with_file(backend, name)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/" .. name
	write(path, ten_lines)
	local commit
	if backend == "jj" then
		run({ "jj", "git", "init" }, dir)
		-- snapshot.auto-track can be disabled in the user's jj config, so
		-- this repo's new file needs explicit tracking regardless of that setting.
		run({ "jj", "file", "track", "--", 'root-file:"' .. name .. '"' }, dir)
		commit = function(message)
			run({ "jj", "commit", "-m", message }, dir)
			return commit_id(dir, "@-")
		end
	else
		run({ "git", "init", "-q" }, dir)
		commit = function(message)
			run({ "git", "add", "--", name }, dir)
			run({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message }, dir)
			return vim.trim(run({ "git", "rev-parse", "HEAD" }, dir).stdout)
		end
	end
	local from = commit("first")
	return { vcs = backend, root = dir }, path, from, function(lines)
		write(path, lines)
		return commit("second")
	end
end

local function with(lines, row, value)
	local copy = vim.deepcopy(lines)
	if value == nil then
		table.remove(copy, row)
	else
		copy[row] = value
	end
	return copy
end

local range = { s = 4, e = 6 }

for _, backend in ipairs({ "jj", "git" }) do
	T[backend .. ": a change inside the range touches it"] = function()
		local repo, path, from, change = repo_with_file(backend, "f.lua")
		local to = change(with(ten_lines, 5, "five"))

		MiniTest.expect.equality(vcs.touches(vcs.hunks(repo, from, to, path), range), true)
	end

	T[backend .. ": a change below the range leaves it untouched"] = function()
		local repo, path, from, change = repo_with_file(backend, "f.lua")
		local to = change(with(ten_lines, 9, "nine"))

		MiniTest.expect.equality(vcs.touches(vcs.hunks(repo, from, to, path), range), false)
	end

	T[backend .. ": an edit above the range that keeps the line count leaves it untouched"] = function()
		local repo, path, from, change = repo_with_file(backend, "f.lua")
		local to = change(with(ten_lines, 1, "one"))

		MiniTest.expect.equality(vcs.touches(vcs.hunks(repo, from, to, path), range), false)
	end

	T[backend .. ": removing a line above the range moves it"] = function()
		local repo, path, from, change = repo_with_file(backend, "f.lua")
		local to = change(with(ten_lines, 2, nil))

		MiniTest.expect.equality(vcs.touches(vcs.hunks(repo, from, to, path), range), true)
	end
end

T["an insertion inside the range touches it; one after it does not"] = function()
	MiniTest.expect.equality(vcs.touches({ { old_start = 5, old_count = 0, new_count = 2 } }, range), true)
	MiniTest.expect.equality(vcs.touches({ { old_start = 6, old_count = 0, new_count = 2 } }, range), false)
	MiniTest.expect.equality(vcs.touches({ { old_start = 3, old_count = 0, new_count = 1 } }, range), true)
end

T["hunks() finds a change to a jj-tracked path starting with a dash"] = function()
	local repo, path, from, change = repo_with_file("jj", "-weird.lua")
	local to = change(with(ten_lines, 5, "five"))

	MiniTest.expect.equality(vcs.touches(vcs.hunks(repo, from, to, path), range), true)
end

T["hunks() finds a change to a jj-tracked path holding glob characters"] = function()
	local repo, path, from, change = repo_with_file("jj", "a[b].lua")
	local to = change(with(ten_lines, 5, "five"))

	MiniTest.expect.equality(vcs.touches(vcs.hunks(repo, from, to, path), range), true)
end

return T
