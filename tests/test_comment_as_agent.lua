local remark = require("remark")
local agent = require("remark.agent")
local store = require("remark.store")

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

-- Bounded so a wedged git process fails this test rather than hanging CI.
local function run(cmd, cwd)
	return vim.system(cmd, { cwd = cwd, text = true }):wait(5000)
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

-- comment_as_agent returns a JSON-encoded string so a --remote-expr caller
-- can parse it; tests decode it back to inspect the { ok, error?, thread_id? }
-- shape.
local function comment_as_agent(...)
	return vim.json.decode(agent.comment_as_agent(...))
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

	local result = comment_as_agent("claude", file, 1, 2, body_path)

	MiniTest.expect.equality(result.ok, true)
	MiniTest.expect.equality(type(result.thread_id), "string")

	local by_id = replay(log_path).by_id
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

	local result = comment_as_agent("claude", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, true)
	local by_id = replay(log_path).by_id
	MiniTest.expect.equality(by_id[result.thread_id].commit, nil)
end

T["rejects an empty agent_name and appends nothing"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")

	local result = comment_as_agent("", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, false)
	local ordered = replay(log_path).ordered
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an unreadable file and appends nothing"] = function()
	local result = comment_as_agent("claude", "/nonexistent/file.lua", 1, 1, "/nonexistent/body.md")

	MiniTest.expect.equality(result.ok, false)
	local ordered = replay(log_path).ordered
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects a relative file path and appends nothing"] = function()
	local dir = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")

	local result = comment_as_agent("claude", "file.lua", 1, 1, body_path)

	MiniTest.expect.equality(result.ok, false)
	MiniTest.expect.equality(result.error, "file must be an absolute path")
	MiniTest.expect.equality(#replay(log_path).ordered, 0)
end

T["records an unnormalised absolute path in the form the gutter matches"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")
	local unnormalised = vim.fn.fnamemodify(file, ":h") .. "/./" .. vim.fn.fnamemodify(file, ":t")

	local result = comment_as_agent("claude", unnormalised, 1, 1, body_path)

	MiniTest.expect.equality(replay(log_path).by_id[result.thread_id].file, file)
end

T["rejects an invalid line range and appends nothing"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "body")

	MiniTest.expect.equality(comment_as_agent("claude", file, 0, 1, body_path).ok, false)
	MiniTest.expect.equality(comment_as_agent("claude", file, 3, 2, body_path).ok, false)

	local ordered = replay(log_path).ordered
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an unreadable body file and appends nothing"] = function()
	local dir, file = init_git_repo()

	local result = comment_as_agent("claude", file, 1, 1, dir .. "/missing.md")

	MiniTest.expect.equality(result.ok, false)
	local ordered = replay(log_path).ordered
	MiniTest.expect.equality(#ordered, 0)
end

T["rejects an empty body file and appends nothing"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "")

	local result = comment_as_agent("claude", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, false)
	local ordered = replay(log_path).ordered
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

	local result = comment_as_agent("claude", file, 1, 1, body_path)

	MiniTest.expect.equality(result.ok, true)
	local by_id = replay(log_path).by_id
	MiniTest.expect.equality(by_id[result.thread_id].comments[1].body, body)
end

T["never raises on a malformed call"] = function()
	MiniTest.expect.no_error(function()
		agent.comment_as_agent(nil, nil, "not-a-number", nil, nil)
	end)
end

T["a refresh error scheduled after a successful write is reported"] = function()
	local dir, file = init_git_repo()
	local body_path = dir .. "/body.md"
	write_file(body_path, "looks fine to me")

	local notified = false
	local orig_notify = vim.notify
	vim.notify = function(...)
		notified = true
	end
	local log = store.new(log_path)
	agent.setup({
		for_dir = function()
			return log
		end,
	}, function()
		error("boom")
	end)

	local result = comment_as_agent("claude", file, 1, 1, body_path)
	MiniTest.expect.equality(result.ok, true)

	vim.wait(50)
	vim.notify = orig_notify

	MiniTest.expect.equality(notified, true)
end

return T
