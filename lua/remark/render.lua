-- Two layers. The indicator layer marks where threads live: a gutter bar in the
-- sign column spanning a thread's range rows, plus a count where more than one
-- thread starts on a row. The body layer shows a thread's comments in a float
-- (show_thread / show_overview), so the code buffer itself stays uncluttered.
-- The float border carries the thread's status; the sign bar shares its colour.

local M = {}

local ns = vim.api.nvim_create_namespace("remark")

local anchors = {} -- extmark id -> thread id, per buffer

local function setup_highlights()
	vim.api.nvim_set_hl(0, "RemarkBorderOpen", { default = true, link = "Title" })
	vim.api.nvim_set_hl(0, "RemarkBorderResolved", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "RemarkBorderOutdated", { default = true, link = "DiagnosticWarn" })
end

-- A thread's status decides its colour, shown on both the gutter bar and the
-- float border: resolved is muted, an open thread whose code has since changed
-- is a warning, an open current thread is a title.
local function status_border(thread)
	if thread.status == "resolved" then
		return "RemarkBorderResolved"
	elseif thread.outdated then
		return "RemarkBorderOutdated"
	end
	return "RemarkBorderOpen"
end

function M.setup()
	setup_highlights()
end

-- Editable markdown buffer for composing a comment, reply, or edit. Submitting
-- with :w or <C-s> calls opts.on_submit with the buffer's text; q dismisses it.
-- Whitespace-only content is treated as a cancel, so an empty draft never
-- records a blank comment. filetype=markdown so renderers like Markview apply,
-- and the buffer is named after the entity's id (opts.id), so each draft has a
-- stable, unique name.
---@param opts { id: string, title?: string, default?: string, on_submit: fun(text: string) }
function M.compose(opts)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	pcall(vim.api.nvim_buf_set_name, buf, "remark://compose/" .. opts.id)
	if opts.default and opts.default ~= "" then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.default, "\n", { plain = true }))
	end

	vim.cmd("botright split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_height(win, math.max(6, math.min(15, vim.api.nvim_buf_line_count(buf) + 2)))
	vim.wo[win].winbar = opts.title or "remark: :w or <C-s> to submit, q to cancel"

	local function submit()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		vim.bo[buf].modified = false
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if text:match("%S") then
			opts.on_submit(text)
		end
	end
	vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		vim.cmd.stopinsert()
		submit()
	end, { buffer = buf })
	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf })
	if opts.default == nil or opts.default == "" then
		vim.cmd.startinsert()
	end
end

function M.render(bufnr, threads)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	anchors[bufnr] = {}

	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local drawn = 0

	-- Count threads per start row so a shared line can show its multiplicity.
	local per_start = {}

	for _, thread in ipairs(threads) do
		if thread.file == bufname then
			local s = math.max(0, math.min(thread.range.s - 1, line_count - 1))
			local e = math.max(0, math.min(thread.range.e - 1, line_count - 1))
			local border = status_border(thread)

			for row = s, e do
				local id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
					sign_text = "▏",
					sign_hl_group = border,
				})
				anchors[bufnr][id] = thread.id
			end

			per_start[s] = (per_start[s] or 0) + 1
			if per_start[s] > 1 then
				vim.api.nvim_buf_set_extmark(bufnr, ns, s, 0, {
					virt_text = { { string.format(" %d threads ", per_start[s]), border } },
					virt_text_pos = "eol",
				})
			end

			drawn = drawn + 1
		end
	end
	return drawn
end

-- The thread ids whose range covers a line, in draw order. thread_at takes the
-- first; threads_at hands the caller all of them to disambiguate.
local function ids_covering(bufnr, lnum)
	local ids, seen = {}, {}
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		local id, row, _, details = mark[1], mark[2], mark[3], mark[4]
		local end_row = details.end_row or row
		if lnum - 1 >= row and lnum - 1 <= end_row then
			local tid = anchors[bufnr] and anchors[bufnr][id]
			if tid and not seen[tid] then
				seen[tid] = true
				ids[#ids + 1] = tid
			end
		end
	end
	return ids
end

function M.thread_at(bufnr, lnum)
	return ids_covering(bufnr, lnum)[1]
end

function M.threads_at(bufnr, lnum)
	return ids_covering(bufnr, lnum)
end

return M
