local remark = require("remark")
local store = require("remark.store")
local uuid = require("remark.uuid")

-- Drives M.edit / M.delete through the live command layer: seeds threads into
-- the same log remark.setup wired, renders them into a named buffer so
-- thread_at_cursor resolves, then acts with the cursor on the thread.
local log_path
local saved_input, saved_notify

local function seed_comment(tid, cid, source, body, meta)
	store.new(log_path):transact(function(snap)
		snap:comment(tid, cid, source, body, meta)
	end)
end

local function seed_thread(tid, cid, file, source, body)
	store.new(log_path):transact(function(snap)
		snap:open_thread(tid, file, { s = 1, e = 1 }, nil)
		snap:comment(tid, cid, source, body, nil)
	end)
end

-- A named, current buffer whose name matches the seeded thread's file, with the
-- cursor on the thread's line so thread_at_cursor finds it after a refresh.
local function show(file)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two" })
	vim.api.nvim_set_current_buf(buf)
	remark.refresh()
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

-- A real file path whose directory exists, so vcs.detect can run git there.
local function tmpfile()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	return dir .. "/f.lua"
end

local function comment_body(tid, cid)
	for _, c in ipairs(store.new(log_path):replay().by_id[tid].comments) do
		if c.id == cid then
			return c.body
		end
	end
	return nil
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			log_path = vim.fn.tempname() .. "/log.ndjson"
			remark.setup({ log_path = log_path, registry_path = vim.fn.tempname() .. "/sessions.json" })
			saved_input, saved_notify = vim.ui.input, vim.notify
			vim.notify = function() end
		end,
		post_case = function()
			vim.ui.input, vim.notify = saved_input, saved_notify
			vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
		end,
	},
})

-- Editability follows authorship: an agent replying after your comment does
-- not lock it out of editing.
T["edits your comment even when an agent replied after it"] = function()
	local file = tmpfile()
	local tid, mine = uuid(), uuid()
	seed_thread(tid, mine, file, "local", "my note")
	seed_comment(tid, uuid(), "agent", "agent reply", { author = "claude" })
	show(file)

	vim.ui.input = function(_, cb)
		cb("my edited note")
	end
	remark.edit()

	MiniTest.expect.equality(comment_body(tid, mine), "my edited note")
end

T["deletes your comment even when an agent replied after it"] = function()
	local file = tmpfile()
	local tid, mine = uuid(), uuid()
	seed_thread(tid, mine, file, "local", "my note")
	seed_comment(tid, uuid(), "agent", "agent reply", { author = "claude" })
	show(file)

	remark.delete()

	MiniTest.expect.equality(comment_body(tid, mine), nil)
end

-- Theirs is read-only: a thread with only an agent's comment offers nothing to
-- edit, and the compose prompt never opens.
T["refuses to edit a thread that has no comment of yours"] = function()
	local file = tmpfile()
	local tid, theirs = uuid(), uuid()
	seed_thread(tid, theirs, file, "agent", "agent note")
	show(file)

	local prompted = false
	vim.ui.input = function(_, cb)
		prompted = true
		cb("should not happen")
	end
	remark.edit()

	MiniTest.expect.equality(prompted, false)
	MiniTest.expect.equality(comment_body(tid, theirs), "agent note")
end

return T
