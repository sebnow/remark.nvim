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

local msg_ns = vim.api.nvim_create_namespace("remark_msg")

local thread_bufs = {} -- thread id -> rendered markdown bufnr
local msg_meta = {} -- thread bufnr -> { extmark id -> { id, source } }

-- ours == authored by us; source=="local" stands in for that.
local function is_ours(comment)
	return comment.source == "local"
end

-- The markdown for a thread, plus a segment per comment (its 0-indexed row span
-- and the comment's id and source) so comment_at can map a cursor back to the
-- comment rendered there. Each comment is a "### who" header, its body, then a
-- blank line; the trailing blank is trimmed.
local function thread_markdown(thread)
	local lines = {}
	local segments = {}
	for _, c in ipairs(thread.comments) do
		local ours = is_ours(c)
		local who = ours and "you" or (c.author or c.source)
		local first = #lines
		lines[#lines + 1] = string.format("### %s%s", who, ours and "" or "  _(read-only)_")
		for _, body_line in ipairs(vim.split(c.body, "\n", { plain = true })) do
			lines[#lines + 1] = body_line
		end
		lines[#lines + 1] = ""
		segments[#segments + 1] = { first = first, last = #lines - 1, id = c.id, source = c.source }
	end
	if lines[#lines] == "" then
		lines[#lines] = nil
		if segments[#segments] then
			segments[#segments].last = segments[#segments].last - 1
		end
	end
	return lines, segments
end

-- The read-only markdown view for a thread, keyed on its id and rebuilt in
-- place so a refresh after a mutation updates any float already showing it.
-- It is wiped once no window shows it. Each comment is tagged with an extmark so comment_at can resolve
-- a cursor line to a specific comment.
function M.thread_buffer(thread)
	local buf = thread_bufs[thread.id]
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
		thread_bufs[thread.id] = buf
		pcall(vim.api.nvim_buf_set_name, buf, "remark://" .. thread.id)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = "markdown"
		vim.b[buf].remark_thread = thread.id
	end
	local lines, segments = thread_markdown(thread)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, msg_ns, 0, -1)
	msg_meta[buf] = {}
	for _, seg in ipairs(segments) do
		local id = vim.api.nvim_buf_set_extmark(buf, msg_ns, seg.first, 0, { end_row = seg.last })
		msg_meta[buf][id] = { id = seg.id, source = seg.source }
	end
	return buf
end

-- Resolves a cursor line in a thread buffer to the { id, source } of the comment
-- rendered there, or nil between comments.
function M.comment_at(buf, lnum)
	local meta = msg_meta[buf]
	if not meta then
		return nil
	end
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, msg_ns, 0, -1, { details = true })) do
		local id, row, _, details = mark[1], mark[2], mark[3], mark[4]
		local end_row = details.end_row or row
		if lnum - 1 >= row and lnum - 1 <= end_row then
			return meta[id]
		end
	end
	return nil
end

local float_win = nil

-- The float border carries the thread's status as a word, matching the colour
-- status_border gives it.
local function status_title(thread)
	if thread.status == "resolved" then
		return " resolved "
	elseif thread.outdated then
		return " outdated "
	end
	return " open "
end

-- The float is sized to its content, capped so a long thread scrolls rather
-- than filling the screen (zoom is the deliberate way to go large).
local function content_size(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	return math.min(width, 80), math.min(#lines, 12)
end

-- Rebuild the open float's content if it is showing thread, leaving no buffer
-- behind when it is not.
function M.refresh_float(thread)
	local buf = thread_bufs[thread.id]
	if float_win and vim.api.nvim_win_is_valid(float_win) and vim.api.nvim_win_get_buf(float_win) == buf then
		M.thread_buffer(thread)
	end
end

function M.close_float()
	if float_win and vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_win_close(float_win, true)
	end
	float_win = nil
end

-- True while the cursor is inside our float, so an auto-close on cursor movement
-- can leave a focused (interactive) float alone.
function M.is_float_focused()
	return float_win ~= nil
		and vim.api.nvim_win_is_valid(float_win)
		and vim.api.nvim_get_current_win() == float_win
end

-- A thread's comments in a float anchored just below its range, focusable when
-- the caller wants to interact with it. Only one float lives at a time.
function M.show_thread(thread, srcwin, focus)
	M.close_float()
	local buf = M.thread_buffer(thread)
	local width, height = content_size(buf)
	float_win = vim.api.nvim_open_win(buf, focus or false, {
		relative = "win",
		win = srcwin,
		bufpos = { thread.range.e - 1, 0 },
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = status_title(thread),
		title_pos = "left",
	})
	vim.wo[float_win].wrap = true
	vim.api.nvim_set_option_value(
		"winhl",
		"Normal:NormalFloat,FloatBorder:" .. status_border(thread),
		{ win = float_win }
	)
	return float_win
end

-- A read-only float listing every thread on a line, for a passive preview.
-- Threads are separated by a horizontal rule.
function M.show_overview(threads, srcwin, endrow)
	M.close_float()
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = {}
	for index, thread in ipairs(threads) do
		if index > 1 then
			lines[#lines + 1] = "---"
		end
		for _, line in ipairs(thread_markdown(thread)) do
			lines[#lines + 1] = line
		end
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	local width, height = content_size(buf)
	float_win = vim.api.nvim_open_win(buf, false, {
		relative = "win",
		win = srcwin,
		bufpos = { endrow, 0 },
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = #threads > 1 and string.format(" %d threads ", #threads) or " thread ",
		title_pos = "left",
	})
	vim.wo[float_win].wrap = true
	return float_win
end

-- Reconfigure the current float to near-fullscreen for reading or editing a long
-- thread without leaving the float.
function M.zoom()
	if not (float_win and vim.api.nvim_win_is_valid(float_win)) then
		return
	end
	local columns, rows = vim.o.columns, vim.o.lines
	vim.api.nvim_win_set_config(float_win, {
		relative = "editor",
		row = 2,
		col = 4,
		width = columns - 8,
		height = rows - 6,
	})
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
