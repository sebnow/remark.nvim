local remark = require("remark")
local render = require("remark.render")
local store = require("remark.store")
local uuid = require("remark.uuid")

-- Drives the interactive float layer: open, per-comment edit/delete from within
-- the float, and the passive hover overview.
local log_path
local saved_notify, saved_select

local function seed_thread(tid, cid, file, source, body)
	store.new(log_path):transact(function(snap)
		snap:open_thread(tid, file, { s = 1, e = 1 }, nil)
		snap:comment(tid, cid, source, body, nil)
	end)
end

local function seed_comment(tid, cid, source, body, meta)
	store.new(log_path):transact(function(snap)
		snap:comment(tid, cid, source, body, meta)
	end)
end

local function tmpfile()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	return dir .. "/f.lua"
end

-- The code buffer, current, with the thread rendered and the cursor on its line.
local function show(file)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two" })
	vim.api.nvim_set_current_buf(buf)
	remark.refresh()
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function replay()
	return store.new(log_path):replay()
end

local function comment_body(tid, cid)
	local thread = replay().by_id[tid]
	if not thread then
		return nil
	end
	for _, c in ipairs(thread.comments) do
		if c.id == cid then
			return c.body
		end
	end
	return nil
end

local function composing()
	return vim.api.nvim_buf_get_name(0):find("remark://compose/", 1, true) ~= nil
end

-- Submit the compose buffer a command left current, as :w does.
local function submit(text)
	vim.cmd("stopinsert")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.cmd("write")
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			log_path = vim.fn.tempname() .. "/log.ndjson"
			remark.setup({ log_path = log_path, registry_path = vim.fn.tempname() .. "/sessions.json" })
			saved_notify, saved_select = vim.notify, vim.ui.select
			vim.notify = function() end
		end,
		post_case = function()
			vim.notify, vim.ui.select = saved_notify, saved_select
			render.close_float()
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_get_name(buf):find("remark://compose/", 1, true) then
					pcall(vim.api.nvim_buf_delete, buf, { force = true })
				end
			end
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if #vim.api.nvim_list_wins() > 1 then
					pcall(vim.api.nvim_win_close, win, true)
				end
			end
		end,
	},
})

T["opens a focused float for the thread under the cursor"] = function()
	local file = tmpfile()
	local tid = uuid()
	seed_thread(tid, uuid(), file, "local", "my note")
	show(file)

	remark.open()

	MiniTest.expect.equality(render.is_float_focused(), true)
	MiniTest.expect.no_equality(vim.api.nvim_buf_get_name(0):find("remark://" .. tid, 1, true), nil)
end

T["edits your comment from within the float"] = function()
	local file = tmpfile()
	local tid, mine = uuid(), uuid()
	seed_thread(tid, mine, file, "local", "my note")
	seed_comment(tid, uuid(), "agent", "agent reply", { author = "claude" })
	show(file)

	remark.open()
	local fbuf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- on "my note"
	remark.edit_here(replay().by_id[tid], fbuf)
	submit("my edited note")

	MiniTest.expect.equality(comment_body(tid, mine), "my edited note")
end

T["refuses to edit theirs from within the float"] = function()
	local file = tmpfile()
	local tid, theirs = uuid(), uuid()
	seed_thread(tid, theirs, file, "agent", "agent note")
	show(file)

	remark.open()
	local fbuf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on the agent's header
	remark.edit_here(replay().by_id[tid], fbuf)

	MiniTest.expect.equality(composing(), false)
	MiniTest.expect.equality(comment_body(tid, theirs), "agent note")
end

T["deletes your comment from within the float, closing it when the thread is gone"] = function()
	local file = tmpfile()
	local tid, mine = uuid(), uuid()
	seed_thread(tid, mine, file, "local", "my note")
	show(file)
	local code_buf = vim.api.nvim_get_current_buf()

	remark.open()
	local fbuf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	remark.delete_here(replay().by_id[tid], fbuf)

	MiniTest.expect.equality(comment_body(tid, mine), nil)
	MiniTest.expect.equality(render.is_float_focused(), false)
	-- The thread is gone; its gutter bar must not linger on the code buffer.
	MiniTest.expect.equality(render.thread_at(code_buf, 1), nil)
end

T["hovers a read-only overview without focusing it"] = function()
	local file = tmpfile()
	seed_thread(uuid(), uuid(), file, "local", "my note")
	show(file)

	remark.hover()

	MiniTest.expect.equality(render.is_float_focused(), false)
	MiniTest.expect.equality(#vim.api.nvim_list_wins(), 2)
end

local function thread_buffer_exists(tid)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf):find("remark://" .. tid, 1, true) then
			return true
		end
	end
	return false
end

T["closing a float wipes its buffer"] = function()
	local file = tmpfile()
	local tid = uuid()
	seed_thread(tid, uuid(), file, "local", "my note")
	show(file)

	remark.open()
	render.close_float()
	MiniTest.expect.equality(thread_buffer_exists(tid), false)

	remark.hover()
	local overview = vim.api.nvim_win_get_buf(vim.api.nvim_list_wins()[2])
	render.close_float()
	MiniTest.expect.equality(vim.api.nvim_buf_is_valid(overview), false)
end

T["an edit submitted after its float closed leaves no thread buffer behind"] = function()
	local file = tmpfile()
	local tid, mine = uuid(), uuid()
	seed_thread(tid, mine, file, "local", "my note")
	show(file)

	remark.open()
	local fbuf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	remark.edit_here(replay().by_id[tid], fbuf)
	render.close_float()
	submit("my edited note")

	MiniTest.expect.equality(comment_body(tid, mine), "my edited note")
	MiniTest.expect.equality(thread_buffer_exists(tid), false)
end

T["disambiguates several threads on a line by asking the user"] = function()
	local file = tmpfile()
	local first, second = uuid(), uuid()
	seed_thread(first, uuid(), file, "local", "first thread")
	seed_thread(second, uuid(), file, "local", "second thread")
	show(file)

	vim.ui.select = function(items, _, on_choice)
		on_choice(items[2])
	end
	remark.open()

	MiniTest.expect.no_equality(vim.api.nvim_buf_get_name(0):find("remark://" .. second, 1, true), nil)
end

return T
