local store = require("remark.store")

local T = MiniTest.new_set()

local function new_store()
	return store.new(vim.fn.tempname() .. "/log.ndjson")
end

T["comment() without meta leaves author nil on replay"] = function()
	local s = new_store()
	local tid = s:open_thread("/tmp/f.lua", { s = 1, e = 1 }, nil)
	s:comment(tid, "local", "looks fine")

	local by_id = s:replay()
	MiniTest.expect.equality(by_id[tid].comments[1].author, nil)
end

-- ADR 0003: source stays the fixed origin label; author is metadata.
T["comment() records meta.author, distinct from source"] = function()
	local s = new_store()
	local tid = s:open_thread("/tmp/f.lua", { s = 1, e = 1 }, nil)
	s:comment(tid, "agent", "guarded it with a lock", { author = "claude" })

	local by_id = s:replay()
	local comment = by_id[tid].comments[1]
	MiniTest.expect.equality(comment.source, "agent")
	MiniTest.expect.equality(comment.author, "claude")
end

T["open_thread_with_comment() opens a thread with its first comment already present"] = function()
	local s = new_store()

	local tid = s:open_thread_with_comment("/tmp/f.lua", { s = 1, e = 1 }, "abc123", "agent", "looks fine", {
		author = "claude",
	})

	local by_id = s:replay()
	local thread = by_id[tid]
	MiniTest.expect.equality(thread.file, "/tmp/f.lua")
	MiniTest.expect.equality(thread.commit, "abc123")
	MiniTest.expect.equality(#thread.comments, 1)
	MiniTest.expect.equality(thread.comments[1].source, "agent")
	MiniTest.expect.equality(thread.comments[1].author, "claude")
	MiniTest.expect.equality(thread.comments[1].body, "looks fine")
end

T["open_thread_with_comment() writes both events in a single append"] = function()
	local s = new_store()

	local writes = 0
	local orig_writefile = vim.fn.writefile
	vim.fn.writefile = function(...)
		writes = writes + 1
		return orig_writefile(...)
	end

	s:open_thread_with_comment("/tmp/f.lua", { s = 1, e = 1 }, nil, "agent", "looks fine", { author = "claude" })

	vim.fn.writefile = orig_writefile
	MiniTest.expect.equality(writes, 1)
end

return T
