-- Threads render as a range highlight and extmark-anchored virtual lines. The
-- sign column belongs to the VCS diff layer, not to comments.

local M = {}

local ns = vim.api.nvim_create_namespace("remark")

local anchors = {} -- extmark id -> thread id, per buffer

local function setup_highlights()
	vim.api.nvim_set_hl(0, "RemarkRange", { default = true, link = "Visual" })
	vim.api.nvim_set_hl(0, "RemarkMeta", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "RemarkLocal", { default = true, link = "Normal" })
	vim.api.nvim_set_hl(0, "RemarkAgent", { default = true, link = "DiagnosticInfo" })
end

function M.setup()
	setup_highlights()
end

local function thread_virt_lines(thread)
	local lines = {}
	local span = thread.range.s == thread.range.e and ("L" .. thread.range.s)
		or string.format("L%d-%d", thread.range.s, thread.range.e)
	local head = (thread.status == "resolved" and "✓" or "●") .. " thread · " .. span
	if thread.status == "resolved" then
		head = head .. " (resolved)"
	end
	table.insert(lines, { { "  " .. head, "RemarkMeta" } })
	for _, c in ipairs(thread.comments) do
		local from_agent = c.source == "agent"
		local hl = from_agent and "RemarkAgent" or "RemarkLocal"
		local who = from_agent and "agent" or "you"
		table.insert(lines, { { "  " .. who .. ": ", "RemarkMeta" }, { c.body, hl } })
	end
	return lines
end

function M.render(bufnr, threads)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	anchors[bufnr] = {}

	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local drawn = 0

	for _, thread in ipairs(threads) do
		if thread.file == bufname then
			local s = math.max(0, math.min(thread.range.s - 1, line_count - 1))
			local e = math.max(0, math.min(thread.range.e - 1, line_count - 1))

			-- hl_eol highlights the range full-width across every covered row.
			local last_len = #(vim.api.nvim_buf_get_lines(bufnr, e, e + 1, false)[1] or "")
			local range_id = vim.api.nvim_buf_set_extmark(bufnr, ns, s, 0, {
				end_row = e,
				end_col = last_len,
				hl_group = "RemarkRange",
				hl_eol = true,
			})
			anchors[bufnr][range_id] = thread.id

			-- Anchor at the last line; virtual lines below the first would split the range.
			local thread_id = vim.api.nvim_buf_set_extmark(bufnr, ns, e, 0, {
				virt_lines = thread_virt_lines(thread),
				virt_lines_above = false,
			})
			anchors[bufnr][thread_id] = thread.id

			drawn = drawn + 1
		end
	end
	return drawn
end

function M.thread_at(bufnr, lnum)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		local id, row, _, details = mark[1], mark[2], mark[3], mark[4]
		local end_row = details.end_row or row
		if lnum - 1 >= row and lnum - 1 <= end_row then
			return anchors[bufnr] and anchors[bufnr][id]
		end
	end
	return nil
end

return M
