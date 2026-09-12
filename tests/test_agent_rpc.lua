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

local function remote_expr(addr, expr)
	return vim.system({ "nvim", "--server", addr, "--remote-expr", expr }, { text = true }):wait()
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
		string.format('v:lua.require("remark").comment_as_agent("claude", "%s", 1, 1, "%s")', file, comment_body)
	)
	MiniTest.expect.equality(comment_res.code, 0)

	-- Read the opened thread_id back from the log rather than parsing
	-- --remote-expr's serialized return value.
	local by_id = remark_store.new(log_path):replay()
	local thread_id = next(by_id)
	MiniTest.expect.equality(type(thread_id), "string")

	local reply_body = dir .. "/reply.md"
	write_file(reply_body, "thanks, fixed")
	local reply_res = remote_expr(
		addr,
		string.format('v:lua.require("remark").reply_as_agent("claude", "%s", "%s")', thread_id, reply_body)
	)
	MiniTest.expect.equality(reply_res.code, 0)

	-- Let the child's scheduled M.refresh callbacks run before inspecting it.
	child.api.nvim_exec_lua("vim.wait(200)", {})

	local by_id_after = remark_store.new(log_path):replay()
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
