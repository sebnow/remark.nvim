local remark = require("remark")
local store = require("remark.store")
local agent = require("remark.agent")

-- A session that moves between repos keeps each repo's threads in that repo's
-- own log, as a session started in each would (ADR 0008).
local registry_path, original_cwd, original_state_home

local function run(cmd, cwd)
	return vim.system(cmd, { cwd = cwd, text = true }):wait(5000)
end

local function init_git_repo()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	run({ "git", "init", "-q" }, dir)
	local root = vim.trim(run({ "git", "rev-parse", "--show-toplevel" }, dir).stdout)
	vim.fn.writefile({ "line one", "line two" }, root .. "/f.lua")
	return root
end

local function log_of(root)
	return store.new(vim.fn.stdpath("state") .. "/remark.nvim/logs/" .. vim.fn.sha256(root) .. ".ndjson")
end

local function read_registry()
	return vim.json.decode(table.concat(vim.fn.readfile(registry_path), "\n"))
end

local function comment_on(file, text)
	vim.cmd.edit(file)
	remark.comment()
	vim.cmd("stopinsert")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
	vim.cmd("write")
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			original_cwd = vim.fn.getcwd()
			original_state_home = vim.env.XDG_STATE_HOME
			vim.env.XDG_STATE_HOME = vim.fn.tempname()
			registry_path = vim.fn.tempname() .. "/sessions.json"
		end,
		post_case = function()
			vim.cmd("silent! %bwipeout!")
			vim.fn.chdir(original_cwd)
			vim.env.XDG_STATE_HOME = original_state_home
		end,
	},
})

T["a comment on a file in another repo lands in that repo's log"] = function()
	local first, second = init_git_repo(), init_git_repo()
	vim.fn.chdir(first)
	remark.setup({ registry_path = registry_path })

	comment_on(second .. "/f.lua", "in the second repo")

	MiniTest.expect.equality(#log_of(second):replay().ordered, 1)
	MiniTest.expect.equality(#log_of(first):replay().ordered, 0)
end

T["a buffer shows the threads of its own repo's log"] = function()
	local first, second = init_git_repo(), init_git_repo()
	vim.fn.chdir(first)
	remark.setup({ registry_path = registry_path })
	comment_on(second .. "/f.lua", "in the second repo")

	vim.cmd.edit(first .. "/f.lua")
	MiniTest.expect.equality(#remark.threads(), 0)
	vim.cmd.edit(second .. "/f.lua")
	MiniTest.expect.equality(#remark.threads(), 1)
end

T["opening another repo registers the session for it, and exit retracts both"] = function()
	local first, second = init_git_repo(), init_git_repo()
	vim.fn.chdir(first)
	remark.setup({ registry_path = registry_path })

	vim.cmd.edit(second .. "/f.lua")
	local registry = read_registry()
	MiniTest.expect.equality(registry[first] ~= nil, true)
	MiniTest.expect.equality(registry[second].serverAddr, vim.v.servername)

	vim.api.nvim_exec_autocmds("VimLeave", { group = "remark" })
	MiniTest.expect.equality(read_registry(), {})
end

local function body_file(text)
	local path = vim.fn.tempname()
	vim.fn.writefile({ text }, path)
	return path
end

T["an agent's calls follow the repo of the file or thread they name"] = function()
	local first, second = init_git_repo(), init_git_repo()
	vim.fn.chdir(first)
	remark.setup({ registry_path = registry_path })

	local opened = vim.json.decode(agent.comment_as_agent("claude", second .. "/f.lua", 1, 1, body_file("found")))
	MiniTest.expect.equality(#log_of(second):replay().ordered, 1)
	MiniTest.expect.equality(#log_of(first):replay().ordered, 0)

	MiniTest.expect.no_equality(agent.unresolved_comments(second):find(opened.thread_id, 1, true), nil)
	MiniTest.expect.equality(agent.unresolved_comments(), "")

	local replied = vim.json.decode(agent.reply_as_agent("claude", opened.thread_id, body_file("fixed")))
	MiniTest.expect.equality(replied.ok, true)
	MiniTest.expect.equality(#log_of(second):replay().by_id[opened.thread_id].comments, 2)
end

return T
