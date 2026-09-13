local store = require("remark.store")
local uuid = require("remark.uuid")

local T = MiniTest.new_set()

local function new_store()
	return store.new(vim.fn.tempname() .. "/log.ndjson")
end

-- Stage a single operation and commit it, the everyday shape of a write:
-- replay, stage against the state, write.
local function open_thread(s, thread_id, file, range, commit)
	s:transact(function(snap)
		snap:open_thread(thread_id, file, range, commit)
	end)
end

local function comment(s, thread_id, comment_id, source, body, meta)
	s:transact(function(snap)
		snap:comment(thread_id, comment_id, source, body, meta)
	end)
end

local function open_thread_with_comment(s, thread_id, comment_id, file, range, commit, source, body, meta)
	s:transact(function(snap)
		snap:open_thread_with_comment(thread_id, comment_id, file, range, commit, source, body, meta)
	end)
end

T["comment() without meta leaves author nil on replay"] = function()
	local s = new_store()
	local tid = uuid()
	open_thread(s, tid, "/tmp/f.lua", { s = 1, e = 1 }, nil)
	comment(s, tid, uuid(), "local", "looks fine")

	local by_id = s:replay().by_id
	MiniTest.expect.equality(by_id[tid].comments[1].author, nil)
end

-- ADR 0003: source stays the fixed origin label; author is metadata.
T["comment() records meta.author, distinct from source"] = function()
	local s = new_store()
	local tid = uuid()
	open_thread(s, tid, "/tmp/f.lua", { s = 1, e = 1 }, nil)
	comment(s, tid, uuid(), "agent", "guarded it with a lock", { author = "claude" })

	local by_id = s:replay().by_id
	local c = by_id[tid].comments[1]
	MiniTest.expect.equality(c.source, "agent")
	MiniTest.expect.equality(c.author, "claude")
end

-- ADR 0009: the client mints identity; the store records the ids it is given.
T["records the thread and comment ids it is given"] = function()
	local s = new_store()
	local tid, cid = uuid(), uuid()

	open_thread_with_comment(s, tid, cid, "/tmp/f.lua", { s = 1, e = 1 }, nil, "local", "hi", nil)

	local by_id = s:replay().by_id
	MiniTest.expect.equality(by_id[tid].id, tid)
	MiniTest.expect.equality(by_id[tid].comments[1].id, cid)
end

-- ADR 0002: log writes are serialised under an advisory lock so two Neovim
-- instances sharing a directory's log do not interleave writes. The lock is a sidecar
-- file held only for the write it guards.
T["releases the log lock once a write completes"] = function()
	local s = new_store()

	open_thread(s, uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil)

	MiniTest.expect.equality(vim.fn.filereadable(s.path .. ".lock"), 0)
end

T["reclaims a lock left behind by a crashed writer"] = function()
	local s = new_store()
	vim.fn.mkdir(vim.fn.fnamemodify(s.path, ":h"), "p")
	-- A lock naming a pid that is no longer alive, as a crashed holder leaves.
	vim.fn.writefile({ "999999" }, s.path .. ".lock")

	open_thread(s, uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil)

	MiniTest.expect.equality(#s:replay().ordered, 1)
	MiniTest.expect.equality(vim.fn.filereadable(s.path .. ".lock"), 0)
end

T["reclaims an empty lock left by a writer that crashed mid-acquire"] = function()
	local s = new_store()
	vim.fn.mkdir(vim.fn.fnamemodify(s.path, ":h"), "p")
	-- Created with O_EXCL but the holder died before recording its pid.
	vim.fn.writefile({}, s.path .. ".lock")

	open_thread(s, uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil)

	MiniTest.expect.equality(#s:replay().ordered, 1)
end

-- ADR 0010: the log grows only by appending, so its byte offset is carried on
-- the state a replay produced -- what a later write compares against before it
-- commits.
T["replay() reports the log's byte offset on the state"] = function()
	local s = new_store()

	MiniTest.expect.equality(s:replay().offset, 0)

	open_thread_with_comment(s, uuid(), uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil, "local", "hi", nil)

	MiniTest.expect.equality(s:replay().offset, vim.fn.getfsize(s.path))
end

-- ADR 0010: a write commits only against the offset it was read at; if another
-- writer appended in between, the commit is refused and nothing lands.
T["write refuses to commit when the log grew since the state was read"] = function()
	local s = new_store()
	local stale = s:replay()

	-- A concurrent writer appends after `stale` was read.
	open_thread(s, uuid(), "/tmp/a.lua", { s = 1, e = 1 }, nil)

	stale:comment(uuid(), uuid(), "local", "made against a stale view")
	MiniTest.expect.equality(s:write(stale), false)

	-- Only the concurrent write survived; the stale one never landed.
	MiniTest.expect.equality(#s:replay().ordered, 1)
end

T["open_thread_with_comment() opens a thread with its first comment already present"] = function()
	local s = new_store()

	local tid = uuid()
	open_thread_with_comment(s, tid, uuid(), "/tmp/f.lua", { s = 1, e = 1 }, "abc123", "agent", "looks fine", {
		author = "claude",
	})

	local thread = s:replay().by_id[tid]
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

	open_thread_with_comment(s, uuid(), uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil, "agent", "looks fine", { author = "claude" })

	vim.fn.writefile = orig_writefile
	MiniTest.expect.equality(writes, 1)
end

T["wipe() truncates the log so a replay yields no threads"] = function()
	local s = new_store()
	open_thread_with_comment(s, uuid(), uuid(), "/tmp/f.lua", { s = 1, e = 1 }, nil, "local", "first", nil)
	open_thread_with_comment(s, uuid(), uuid(), "/tmp/g.lua", { s = 2, e = 3 }, nil, "local", "second", nil)

	s:wipe()

	local snap = s:replay()
	MiniTest.expect.equality(next(snap.by_id), nil)
	MiniTest.expect.equality(#snap.ordered, 0)
end

T["wipe() is safe on a log that was never written"] = function()
	local s = new_store()

	s:wipe()

	MiniTest.expect.equality(#s:replay().ordered, 0)
end

return T
