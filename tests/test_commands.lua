local remark = require("remark")
local store = require("remark.store")
local uuid = require("remark.uuid")

-- Drives the command layer (comment, reply, edit, delete) through the real
-- compose buffer: seeds threads into the same log remark.setup wired, renders
-- them into a named buffer so thread_at_cursor resolves, invokes the command,
-- then submits the compose buffer it opened by writing it (:w).
local log_path
local saved_notify

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

-- A real file path whose directory exists, so vcs.detect can run git there.
local function tmpfile()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	return dir .. "/f.lua"
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

-- True while the current buffer is a compose draft a command just opened.
local function composing()
	return vim.api.nvim_buf_get_name(0):find("remark://compose/", 1, true) ~= nil
end

-- Submit the compose buffer a command left current, as :w does.
local function submit(text)
	local buf = vim.api.nvim_get_current_buf()
	vim.cmd("stopinsert")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.cmd("write")
end

local function replay()
	return store.new(log_path):replay()
end

local function comment_body(tid, cid)
	for _, c in ipairs(replay().by_id[tid].comments) do
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
			saved_notify = vim.notify
			vim.notify = function() end
		end,
		post_case = function()
			vim.notify = saved_notify
			-- A case that opens a compose draft without submitting leaves a
			-- modified buffer; force it (and its window) away so switching
			-- buffers in the next case does not raise E37.
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if #vim.api.nvim_list_wins() > 1 then
					pcall(vim.api.nvim_win_close, win, true)
				end
			end
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_get_name(buf):find("remark://compose/", 1, true) then
					pcall(vim.api.nvim_buf_delete, buf, { force = true })
				end
			end
		end,
	},
})

T["records a local thread and comment when you submit a comment"] = function()
	local file = tmpfile()
	show(file)

	remark.comment()
	MiniTest.expect.equality(composing(), true)
	submit("a fresh remark")

	local ordered = replay().ordered
	MiniTest.expect.equality(#ordered, 1)
	MiniTest.expect.equality(ordered[1].file, file)
	MiniTest.expect.equality(ordered[1].comments[1].source, "local")
	MiniTest.expect.equality(ordered[1].comments[1].body, "a fresh remark")
end

T["refuses to comment in a buffer that is not a file"] = function()
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
	remark.comment()
	MiniTest.expect.equality(composing(), false)

	local scratch = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(scratch, "scratch-" .. uuid())
	vim.api.nvim_set_current_buf(scratch)
	remark.comment()
	MiniTest.expect.equality(composing(), false)
end

T["appends a local reply to the thread under the cursor"] = function()
	local file = tmpfile()
	local tid = uuid()
	seed_thread(tid, uuid(), file, "local", "opening note")
	show(file)

	remark.user_reply()
	MiniTest.expect.equality(composing(), true)
	submit("a reply")

	local comments = replay().by_id[tid].comments
	MiniTest.expect.equality(#comments, 2)
	MiniTest.expect.equality(comments[2].source, "local")
	MiniTest.expect.equality(comments[2].body, "a reply")
end

-- Editability follows authorship: an agent replying after your comment does
-- not lock it out of editing.
T["edits your comment even when an agent replied after it"] = function()
	local file = tmpfile()
	local tid, mine = uuid(), uuid()
	seed_thread(tid, mine, file, "local", "my note")
	seed_comment(tid, uuid(), "agent", "agent reply", { author = "claude" })
	show(file)

	remark.edit()
	MiniTest.expect.equality(composing(), true)
	submit("my edited note")

	MiniTest.expect.equality(comment_body(tid, mine), "my edited note")
end

T["prefills the edit draft with the comment's current body"] = function()
	local file = tmpfile()
	local tid, mine = uuid(), uuid()
	seed_thread(tid, mine, file, "local", "my note")
	show(file)

	remark.edit()

	MiniTest.expect.equality(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "my note" })
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
-- edit, so no compose draft opens.
T["refuses to edit a thread that has no comment of yours"] = function()
	local file = tmpfile()
	local tid, theirs = uuid(), uuid()
	seed_thread(tid, theirs, file, "agent", "agent note")
	show(file)

	remark.edit()

	MiniTest.expect.equality(composing(), false)
	MiniTest.expect.equality(comment_body(tid, theirs), "agent note")
end

return T
