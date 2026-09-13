-- Drives the real transport (a separate `nvim --server <addr> --remote-expr`
-- process) against a live mini.test child session, per ADR 0007: the risk
-- sits in discovery, argument escaping, and the scheduled redraw, not in the
-- function run on its own, so an in-process call would hide those faults.
local child = MiniTest.new_child_neovim()
local remark_store = require("remark.store")

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

-- Bounded so a wedged child session fails this test rather than hanging CI.
local function remote_expr(addr, expr)
	return vim.system({ "nvim", "--server", addr, "--remote-expr", expr }, { text = true }):wait(5000)
end

local log_path

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			log_path = vim.fn.tempname() .. "/log.ndjson"
			vim.env.REVIEW_TEST_LOG_PATH = log_path
			child.start({ "-u", "tests/agent_rpc_init.lua" })
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["comment_as_agent then reply_as_agent over --remote-expr open a thread, append a reply, and re-render live"] = function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local file = dir .. "/file.lua"
	write_file(file, "line one\nline two\nline three\n")

	child.cmd("edit " .. file)
	local addr = child.v.servername

	local comment_body = dir .. "/comment.md"
	write_file(comment_body, "looks fine to me")
	local comment_res = remote_expr(
		addr,
		string.format('v:lua.require("remark.agent").comment_as_agent("claude", "%s", 1, 1, "%s")', file, comment_body)
	)
	MiniTest.expect.equality(comment_res.code, 0)

	-- comment_as_agent returns vim.json.encode({ ok, thread_id }); decoding
	-- --remote-expr's stdout is how a real agent learns the new thread_id.
	local comment_result = vim.json.decode(vim.trim(comment_res.stdout))
	MiniTest.expect.equality(comment_result.ok, true)
	local thread_id = comment_result.thread_id
	MiniTest.expect.equality(type(thread_id), "string")

	local reply_body = dir .. "/reply.md"
	write_file(reply_body, "thanks, fixed")
	local reply_res = remote_expr(
		addr,
		string.format('v:lua.require("remark.agent").reply_as_agent("claude", "%s", "%s")', thread_id, reply_body)
	)
	MiniTest.expect.equality(reply_res.code, 0)
	local reply_result = vim.json.decode(vim.trim(reply_res.stdout))
	MiniTest.expect.equality(reply_result.ok, true)

	-- Let the child's scheduled M.refresh callbacks run before inspecting it.
	child.api.nvim_exec_lua("vim.wait(200)", {})

	local by_id_after = remark_store.new(log_path):replay().by_id
	local comments = by_id_after[thread_id].comments
	MiniTest.expect.equality(#comments, 2)
	MiniTest.expect.equality(comments[1].body, "looks fine to me")
	MiniTest.expect.equality(comments[2].body, "thanks, fixed")

	-- Rows 23-24 (statusline/cmdline) embed the unique tempdir path used for
	-- `file`, which differs on every run; only the buffer content above it is
	-- the stable, meaningful part of this screenshot.
	MiniTest.expect.reference_screenshot(child.get_screenshot(), nil, { ignore_text = { 23, 24 } })
end

return T
