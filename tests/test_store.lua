local store = require("remark.store")
local uuid = require("remark.uuid")

local T = MiniTest.new_set()

local function new_store()
	return store.new(vim.fn.tempname() .. "/log.ndjson")
end

T["comment() without meta leaves author nil on replay"] = function()
	local s = new_store()
	local tid = uuid()
	s:open_thread(tid, "/tmp/f.lua", { s = 1, e = 1 }, nil)
	s:comment(tid, uuid(), "local", "looks fine")

	local by_id = s:replay()
	MiniTest.expect.equality(by_id[tid].comments[1].author, nil)
end

-- ADR 0003: source stays the fixed origin label; author is metadata.
T["comment() records meta.author, distinct from source"] = function()
	local s = new_store()
	local tid = uuid()
	s:open_thread(tid, "/tmp/f.lua", { s = 1, e = 1 }, nil)
	s:comment(tid, uuid(), "agent", "guarded it with a lock", { author = "claude" })

	local by_id = s:replay()
	local comment = by_id[tid].comments[1]
	MiniTest.expect.equality(comment.source, "agent")
	MiniTest.expect.equality(comment.author, "claude")
end

-- ADR 0009: the client mints identity; the store records the ids it is given.
T["records the thread and comment ids it is given"] = function()
	local s = new_store()
	local tid, cid = uuid(), uuid()

	s:open_thread_with_comment(tid, cid, "/tmp/f.lua", { s = 1, e = 1 }, nil, "local", "hi", nil)

	local by_id = s:replay()
	MiniTest.expect.equality(by_id[tid].id, tid)
	MiniTest.expect.equality(by_id[tid].comments[1].id, cid)
end

-- ADR 0002: log writes are serialised under an advisory lock so two Neovim
-- instances sharing a directory's log do not interleave writes. The lock is a sidecar
-- file held only for the write it guards.
T["releases the log lock once a write completes"] = function()
	local s = new_store()

	s:open_thread(uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil)

	MiniTest.expect.equality(vim.fn.filereadable(s.path .. ".lock"), 0)
end

T["reclaims a lock left behind by a crashed writer"] = function()
	local s = new_store()
	vim.fn.mkdir(vim.fn.fnamemodify(s.path, ":h"), "p")
	-- A lock naming a pid that is no longer alive, as a crashed holder leaves.
	vim.fn.writefile({ "999999" }, s.path .. ".lock")

	s:open_thread(uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil)

	local _, ordered = s:replay()
	MiniTest.expect.equality(#ordered, 1)
	MiniTest.expect.equality(vim.fn.filereadable(s.path .. ".lock"), 0)
end

T["reclaims an empty lock left by a writer that crashed mid-acquire"] = function()
	local s = new_store()
	vim.fn.mkdir(vim.fn.fnamemodify(s.path, ":h"), "p")
	-- Created with O_EXCL but the holder died before recording its pid.
	vim.fn.writefile({}, s.path .. ".lock")

	s:open_thread(uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil)

	local _, ordered = s:replay()
	MiniTest.expect.equality(#ordered, 1)
end

-- ADR 0010: the log grows only by appending, so its byte length is the version
-- of the state a replay produced -- what a later write compares against before
-- it commits.
T["replay() reports the log's byte length as the version"] = function()
	local s = new_store()

	local _, _, empty_version = s:replay()
	MiniTest.expect.equality(empty_version, 0)

	s:open_thread_with_comment(uuid(), uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil, "local", "hi", nil)

	local _, _, version = s:replay()
	MiniTest.expect.equality(version, vim.fn.getfsize(s.path))
end

T["open_thread_with_comment() opens a thread with its first comment already present"] = function()
	local s = new_store()

	local tid = uuid()
	s:open_thread_with_comment(tid, uuid(), "/tmp/f.lua", { s = 1, e = 1 }, "abc123", "agent", "looks fine", {
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

	s:open_thread_with_comment(uuid(), uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil, "agent", "looks fine", { author = "claude" })

	vim.fn.writefile = orig_writefile
	MiniTest.expect.equality(writes, 1)
end

T["wipe() truncates the log so a replay yields no threads"] = function()
	local s = new_store()
	s:open_thread_with_comment(uuid(), uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil, "local", "first", nil)
	s:open_thread_with_comment(uuid(), uuid(), "/tmp/g.lua", { s = 2, e = 3 }, nil, "local", "second", nil)

	s:wipe()

	local by_id, ordered = s:replay()
	MiniTest.expect.equality(next(by_id), nil)
	MiniTest.expect.equality(#ordered, 0)
end

T["wipe() is safe on a log that was never written"] = function()
	local s = new_store()

	s:wipe()

	local _, ordered = s:replay()
	MiniTest.expect.equality(#ordered, 0)
end

return T
