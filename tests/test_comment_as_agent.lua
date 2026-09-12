local remark = require("remark")
local agent = require("remark.agent")
local store = require("remark.store")

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local function run(cmd, cwd)
	return vim.system(cmd, { cwd = cwd, text = true }):wait()
end

-- A throwaway git repo with one commit, for anchoring tests.
local function init_git_repo()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	run({ "git", "init", "-q" }, dir)
	run({ "git", "config", "user.email", "test@example.com" }, dir)
	run({ "git", "config", "user.name", "test" }, dir)
	local file = dir .. "/file.lua"
	write_file(file, "line one\nline two\nline three\n")
	run({ "git", "add", "." }, dir)
	run({ "git", "commit", "-q", "-m", "init" }, dir)
	local head = vim.trim(run({ "git", "rev-parse", "HEAD" }, dir).stdout)
	return dir, file, head
end

-- Replays the same NDJSON log comment_as_agent wrote through, independent of
-- remark.init's own singleton store (the log is the canonical store, ADR 0001).
local function replay(log_path)
	return store.new(log_path):replay()
end

local log_path

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			log_path = vim.fn.tempname() .. "/log.ndjson"
			-- Isolates this test's session registration from the developer's
			-- real state dir (session.register would otherwise write there).
			remark.setup({ log_path = log_path, registry_path = vim.fn.tempname() .. "/sessions.json" })
		end,
	},
})

T["opens a thread anchored to the current commit and appends one agent comment"] = function()
	local dir, file, head = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "looks fine to me")

	local result = agent.comment_as_agent("claude", file, 1, 2, body_path)

	MiniTest.expect.equality(result.ok, true)
	MiniTest.expect.equality(type(result.thread_id), "string")

	local by_id = replay(log_path)
	local thread = by_id[result.thread_id]
	MiniTest.expect.equality(thread.file, file)
	MiniTest.expect.equality(thread.range, { s = 1, e = 2 })
	MiniTest.expect.equality(thread.commit, head)
	MiniTest.expect.equality(#thread.comments, 1)
	MiniTest.expect.equality(thread.comments[1].source, "agent")
	MiniTest.expect.equality(thread.comments[1].author, "claude")
	MiniTest.expect.equality(thread.comments[1].body, "looks fine to me")
end

T["opens a thread with no commit anchor outside a repo"] = function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local file = dir .. "/file.lua"
	write_file(file, "line one\n")
	local body_path = dir .. "/body.md"
	write_file(body_path, "no repo here")

	local result = agent.comment_as_agent("claude", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, true)
	local by_id = replay(log_path)
	MiniTest.expect.equality(by_id[result.thread_id].commit, nil)
end

T["rejects an empty agent_name and appends nothing"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")

	local result = agent.comment_as_agent("", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, false)
	local _, ordered = replay(log_path)
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an unreadable file and appends nothing"] = function()
	local result = agent.comment_as_agent("claude", "/nonexistent/file.lua", 1, 1, "/nonexistent/body.md")

	MiniTest.expect.equality(result.ok, false)
	local _, ordered = replay(log_path)
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an invalid line range and appends nothing"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")

	MiniTest.expect.equality(agent.comment_as_agent("claude", file, 0, 1, body_path).ok, false)
	MiniTest.expect.equality(agent.comment_as_agent("claude", file, 3, 2, body_path).ok, false)

	local _, ordered = replay(log_path)
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an unreadable body file and appends nothing"] = function()
	local dir, file = init_git_repo()

	local result = agent.comment_as_agent("claude", file, 1, 1, dir .. "/missing.md")

	MiniTest.expect.equality(result.ok, false)
	local _, ordered = replay(log_path)
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an empty body file and appends nothing"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "")

	local result = agent.comment_as_agent("claude", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, false)
	local _, ordered = replay(log_path)
	MiniTest.expect.equality(#ordered, 0)
end

T["round-trips a large multi-line body with quotes and backticks"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	local lines = {}
	for i = 1, 500 do
		table.insert(lines, string.format('line %d with "quotes" and `backticks`', i))
	end
	local body = table.concat(lines, "\n")
	write_file(body_path, body)

	local result = agent.comment_as_agent("claude", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, true)
	local by_id = replay(log_path)
	MiniTest.expect.equality(by_id[result.thread_id].comments[1].body, body)
end

T["never raises on a malformed call"] = function()
	MiniTest.expect.no_error(function()
		agent.comment_as_agent(nil, nil, "not-a-number", nil, nil)
	end)
end

return T
