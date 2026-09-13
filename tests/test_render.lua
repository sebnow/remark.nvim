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

return T
