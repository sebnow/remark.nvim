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

return T
