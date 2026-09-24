local render = require("remark.render")
local uuid = require("remark.uuid")

-- compose opens an editable buffer in a split and makes it current; these tests
-- drive it through the real submit path (:w on the acwrite buffer) and clean up
-- any window/buffer a case leaves behind.
local T = MiniTest.new_set({
	hooks = {
		post_case = function()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if #vim.api.nvim_list_wins() > 1 then
					pcall(vim.api.nvim_win_close, win, true)
				end
			end
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				local name = vim.api.nvim_buf_get_name(buf)
				if name:find("remark://compose/", 1, true) then
					pcall(vim.api.nvim_buf_delete, buf, { force = true })
				end
			end
		end,
	},
})

T["submits the buffer's text on :w"] = function()
	local submitted
	render.compose({ id = uuid(), on_submit = function(text)
		submitted = text
	end })

	local buf = vim.api.nvim_get_current_buf()
	vim.cmd("stopinsert")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two" })
	vim.cmd("write")

	MiniTest.expect.equality(submitted, "line one\nline two")
	-- The compose window closes once its content is submitted.
	MiniTest.expect.equality(vim.api.nvim_buf_is_valid(buf), false)
end

T["prefills the buffer with the default body"] = function()
	render.compose({ id = uuid(), default = "existing\nbody", on_submit = function() end })

	local buf = vim.api.nvim_get_current_buf()
	MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "existing", "body" })
end

-- ADR 0009: the draft is keyed on the entity's minted id, so its buffer name is
-- stable and unique per entity.
T["names the buffer for the entity being composed"] = function()
	local id = uuid()
	render.compose({ id = id, on_submit = function() end })

	local name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
	MiniTest.expect.no_equality(name:find("remark://compose/" .. id, 1, true), nil)
end

T["keeps the draft open when submitting fails"] = function()
	local saved_notify = vim.notify
	vim.notify = function() end
	render.compose({ id = uuid(), on_submit = function()
		error("lock deadline")
	end })

	local buf = vim.api.nvim_get_current_buf()
	vim.cmd("stopinsert")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "keep me" })
	vim.cmd("write")
	vim.notify = saved_notify

	MiniTest.expect.equality(vim.api.nvim_get_current_buf(), buf)
	MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "keep me" })
end

T["does not submit whitespace-only content"] = function()
	local called = false
	render.compose({ id = uuid(), on_submit = function()
		called = true
	end })

	local buf = vim.api.nvim_get_current_buf()
	vim.cmd("stopinsert")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "   ", "" })
	vim.cmd("write")

	MiniTest.expect.equality(called, false)
	-- Even an empty submit dismisses the buffer, like cancelling.
	MiniTest.expect.equality(vim.api.nvim_buf_is_valid(buf), false)
end

return T
