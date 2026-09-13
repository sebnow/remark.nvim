local remark = require("remark")

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			remark.setup({
				log_path = vim.fn.tempname() .. "/log.ndjson",
				registry_path = vim.fn.tempname() .. "/sessions.json",
			})
		end,
		post_case = function()
			-- Leave a plain buffer current so the BufEnter refresh a later test
			-- triggers does not land on this one's special buffer.
			vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
		end,
	},
})

-- refresh runs on every BufEnter, including onto our own compose buffers and
-- terminals, whose names ("remark://...", "term://...") are not real paths.
-- Deriving a vcs cwd from such a name spawns git in a directory that does not
-- exist; refresh must recognise a special buffer and skip it.
T["ignores a special (non-file) buffer instead of running vcs against its name"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "acwrite"
	vim.api.nvim_buf_set_name(buf, "remark://compose/x")

	MiniTest.expect.no_error(function()
		vim.api.nvim_set_current_buf(buf)
		remark.refresh()
	end)
end

return T
