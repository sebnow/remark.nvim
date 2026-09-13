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

return T
