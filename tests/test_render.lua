local render = require("remark.render")
local uuid = require("remark.uuid")

local function buf_with(file, nlines)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, file)
	local lines = {}
	for i = 1, nlines do
		lines[i] = "line " .. i
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

local function thread(file, s, e)
	return { id = uuid(), file = file, range = { s = s, e = e }, comments = {}, status = "unresolved" }
end

local function has(ids, id)
	for _, v in ipairs(ids) do
		if v == id then
			return true
		end
	end
	return false
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			render.setup()
		end,
		post_case = function()
			render.close_float()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if #vim.api.nvim_list_wins() > 1 then
					pcall(vim.api.nvim_win_close, win, true)
				end
			end
		end,
	},
})

T["resolves the thread whose range covers a line"] = function()
	local buf = buf_with(vim.fn.tempname() .. "-x.lua", 5)
	local file = vim.api.nvim_buf_get_name(buf)
	local t = thread(file, 2, 3)

	render.render(buf, { t })

	MiniTest.expect.equality(render.thread_at(buf, 2), t.id)
	MiniTest.expect.equality(render.thread_at(buf, 3), t.id)
	MiniTest.expect.equality(render.thread_at(buf, 1), nil)
	MiniTest.expect.equality(render.thread_at(buf, 4), nil)
end

T["returns every thread covering a shared line"] = function()
	local buf = buf_with(vim.fn.tempname() .. "-x.lua", 5)
	local file = vim.api.nvim_buf_get_name(buf)
	local t1 = thread(file, 1, 2)
	local t2 = thread(file, 2, 4)

	render.render(buf, { t1, t2 })

	local ids = render.threads_at(buf, 2)
	MiniTest.expect.equality(#ids, 2)
	MiniTest.expect.equality(has(ids, t1.id), true)
	MiniTest.expect.equality(has(ids, t2.id), true)
end

T["does not draw a thread anchored in another file"] = function()
	local buf = buf_with(vim.fn.tempname() .. "-x.lua", 5)
	local other = thread(vim.fn.tempname() .. "-other.lua", 1, 1)

	local drawn = render.render(buf, { other })

	MiniTest.expect.equality(drawn, 0)
	MiniTest.expect.equality(render.thread_at(buf, 1), nil)
end

local function conversation()
	return {
		id = uuid(),
		file = "x",
		range = { s = 1, e = 1 },
		status = "unresolved",
		comments = {
			{ id = uuid(), source = "local", body = "my note" },
			{ id = uuid(), source = "agent", author = "claude", body = "agent note" },
		},
	}
end

T["renders comments as markdown, labelling yours and marking theirs read-only"] = function()
	local t = conversation()

	local buf = render.thread_buffer(t)

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(lines, {
		"### you",
		"my note",
		"",
		"### claude  _(read-only)_",
		"agent note",
	})
end

T["resolves a cursor line in the thread buffer to its comment"] = function()
	local t = conversation()
	local mine, theirs = t.comments[1], t.comments[2]

	local buf = render.thread_buffer(t)

	MiniTest.expect.equality(render.comment_at(buf, 1).id, mine.id)
	MiniTest.expect.equality(render.comment_at(buf, 2).id, mine.id)
	MiniTest.expect.equality(render.comment_at(buf, 4).id, theirs.id)
	MiniTest.expect.equality(render.comment_at(buf, 5).source, "agent")
end

T["names the thread buffer for its id and reuses it across renders"] = function()
	local t = conversation()

	local first = render.thread_buffer(t)
	local second = render.thread_buffer(t)

	MiniTest.expect.equality(first, second)
	local name = vim.api.nvim_buf_get_name(first)
	MiniTest.expect.no_equality(name:find("remark://" .. t.id, 1, true), nil)
end

-- A source window a float can anchor into, showing a buffer with enough lines
-- for the thread's range.
local function srcwin()
	local buf = buf_with(vim.fn.tempname() .. "-x.lua", 5)
	vim.api.nvim_set_current_buf(buf)
	return vim.api.nvim_get_current_win()
end

T["opens a focused float showing the thread's buffer"] = function()
	local win = srcwin()
	local t = conversation()

	local fwin = render.show_thread(t, win, true)

	MiniTest.expect.equality(vim.api.nvim_win_is_valid(fwin), true)
	MiniTest.expect.equality(render.is_float_focused(), true)
	MiniTest.expect.equality(vim.api.nvim_win_get_buf(fwin), render.thread_buffer(t))
end

T["closes the float and reports it unfocused"] = function()
	local win = srcwin()
	local fwin = render.show_thread(conversation(), win, true)

	render.close_float()

	MiniTest.expect.equality(vim.api.nvim_win_is_valid(fwin), false)
	MiniTest.expect.equality(render.is_float_focused(), false)
end

T["shows only one float at a time"] = function()
	local win = srcwin()

	local first = render.show_thread(conversation(), win, false)
	local second = render.show_thread(conversation(), win, false)

	MiniTest.expect.equality(vim.api.nvim_win_is_valid(first), false)
	MiniTest.expect.equality(vim.api.nvim_win_is_valid(second), true)
end

T["overviews several threads separated by a rule"] = function()
	local win = srcwin()

	local fwin = render.show_overview({ conversation(), conversation() }, win, 0)

	local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(fwin), 0, -1, false)
	MiniTest.expect.no_equality(vim.tbl_contains(lines, "---"), false)
end

T["zooms the float to an editor-relative window"] = function()
	local win = srcwin()
	local fwin = render.show_thread(conversation(), win, true)

	render.zoom()

	MiniTest.expect.equality(vim.api.nvim_win_get_config(fwin).relative, "editor")
end

return T
