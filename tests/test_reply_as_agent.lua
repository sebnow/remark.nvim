local remark = require("remark")
local agent = require("remark.agent")
local store = require("remark.store")

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

-- Replays the same NDJSON log reply_as_agent wrote through, independent of
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

-- An existing thread to reply to, opened through the store directly (no repo
-- needed: reply_as_agent's contracts don't touch anchoring).
local function open_thread()
	return store.new(log_path):open_thread("/tmp/f.lua", { s = 1, e = 1 }, nil)
end

T["appends exactly one agent comment to an existing thread"] = function()
	local thread_id = open_thread()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local body_path = dir .. "/body.md"
	write_file(body_path, "guarded it with a lock")

	local result = agent.reply_as_agent("claude", thread_id, body_path)

	MiniTest.expect.equality(result.ok, true)
	local by_id = replay(log_path)
	local comments = by_id[thread_id].comments
	MiniTest.expect.equality(#comments, 1)
	MiniTest.expect.equality(comments[1].source, "agent")
	MiniTest.expect.equality(comments[1].author, "claude")
	MiniTest.expect.equality(comments[1].body, "guarded it with a lock")
end

T["rejects an empty agent_name and appends nothing"] = function()
	local thread_id = open_thread()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")

	local result = agent.reply_as_agent("", thread_id, body_path)

	MiniTest.expect.equality(result.ok, false)
	MiniTest.expect.equality(#replay(log_path)[thread_id].comments, 0)
end

T["rejects an unknown thread_id and appends nothing"] = function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")

	local result = agent.reply_as_agent("claude", "does-not-exist", body_path)

	MiniTest.expect.equality(result.ok, false)
	local _, ordered = replay(log_path)
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an unreadable body path and appends nothing"] = function()
	local thread_id = open_thread()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")

	local result = agent.reply_as_agent("claude", thread_id, dir .. "/missing.md")

	MiniTest.expect.equality(result.ok, false)
	MiniTest.expect.equality(#replay(log_path)[thread_id].comments, 0)
end

T["rejects an empty body file and appends nothing"] = function()
	local thread_id = open_thread()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local body_path = dir .. "/body.md"
	write_file(body_path, "")

	local result = agent.reply_as_agent("claude", thread_id, body_path)

	MiniTest.expect.equality(result.ok, false)
	MiniTest.expect.equality(#replay(log_path)[thread_id].comments, 0)
end

T["round-trips a large multi-line body with quotes and backticks"] = function()
	local thread_id = open_thread()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local body_path = dir .. "/body.md"
	local lines = {}
	for i = 1, 500 do
		table.insert(lines, string.format('line %d with "quotes" and `backticks`', i))
	end
	local body = table.concat(lines, "\n")
	write_file(body_path, body)

	local result = agent.reply_as_agent("claude", thread_id, body_path)

	MiniTest.expect.equality(result.ok, true)
	MiniTest.expect.equality(replay(log_path)[thread_id].comments[1].body, body)
end

T["never raises on a malformed call"] = function()
	MiniTest.expect.no_error(function()
		agent.reply_as_agent(nil, nil, nil)
	end)
end

return T
