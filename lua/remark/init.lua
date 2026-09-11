local store = require("remark.store")
local render = require("remark.render")
local vcs = require("remark.vcs")

local M = {}

local state = {
	store = nil,
	by_id = {}, -- threadId -> thread
}

local function default_log_path()
	return vim.fn.getcwd() .. "/.remark-state/log.ndjson"
end

function M.refresh()
	local by_id, ordered = state.store:replay()
	state.by_id = by_id
	local bufnr = vim.api.nvim_get_current_buf()
	local file = vim.api.nvim_buf_get_name(bufnr)
	local repo = file ~= "" and vcs.detect(vim.fn.fnamemodify(file, ":h")) or nil
	local head = repo and vcs.head(repo)
	if head then
		for _, t in ipairs(ordered) do
			if t.file == file and t.commit then
				t.outdated = vcs.changed(repo, t.commit, head, t.file)
			end
		end
	end
	return render.render(bufnr, ordered)
end

local function thread_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local id = render.thread_at(bufnr, lnum)
	if not id then
		return nil
	end
	return state.by_id[id]
end

function M.comment(line1, line2)
	local bufnr = vim.api.nvim_get_current_buf()
	local file = vim.api.nvim_buf_get_name(bufnr)
	local range = { s = line1, e = line2 }
	local repo = vcs.detect(vim.fn.fnamemodify(file, ":h"))
	local commit = repo and vcs.head(repo)
	vim.ui.input({ prompt = "Comment: " }, function(body)
		if not body or body == "" then
			return
		end
		local tid = state.store:open_thread(file, range, commit)
		state.store:comment(tid, "local", body)
		M.refresh()
	end)
end

-- Agent entry point, called over --remote-expr. Only appends a comment; the
-- user owns resolution.
function M.reply(thread_id, body)
	if not (state.by_id[thread_id] and body and body ~= "") then
		return false
	end
	state.store:comment(thread_id, "agent", body)
	vim.schedule(M.refresh)
	return true
end

function M.user_reply()
	local thread = thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	vim.ui.input({ prompt = "Reply: " }, function(body)
		if not body or body == "" then
			return
		end
		state.store:comment(thread.id, "local", body)
		M.refresh()
	end)
end

local function set_status(status)
	local thread = thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	state.store:set_status(thread.id, status)
	M.refresh()
end

function M.resolve()
	set_status("resolved")
end

function M.unresolve()
	set_status("unresolved")
end

-- Mutable only while it is the tail comment and yours.
local function tail_local_comment(thread)
	local last = thread.comments[#thread.comments]
	if last and last.source == "local" then
		return last
	end
	return nil
end

function M.edit()
	local thread = thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	local c = tail_local_comment(thread)
	if not c then
		vim.notify("remark: tail comment is not yours to edit", vim.log.levels.WARN)
		return
	end
	vim.ui.input({ prompt = "Edit: ", default = c.body }, function(body)
		if not body or body == "" then
			return
		end
		state.store:edit_comment(c.id, body)
		M.refresh()
	end)
end

function M.delete()
	local thread = thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	local c = tail_local_comment(thread)
	if not c then
		vim.notify("remark: tail comment is not yours to delete", vim.log.levels.WARN)
		return
	end
	state.store:delete_comment(c.id)
	M.refresh()
end

-- One quickfix entry per thread, so pickers like Telescope can consume it.
function M.list()
	local _, ordered = state.store:replay()
	local items = {}
	for _, t in ipairs(ordered) do
		local marker = t.status == "resolved" and "✓" or "●"
		local first = t.comments[1]
		local who = first and (first.source == "agent" and "agent" or "you") or "?"
		local body = first and first.body or ""
		local more = #t.comments > 1 and string.format(" (+%d)", #t.comments - 1) or ""
		table.insert(items, {
			filename = t.file,
			lnum = t.range.s,
			col = 1,
			text = string.format("%s %s: %s%s", marker, who, body, more),
		})
	end
	vim.fn.setqflist({}, " ", { title = "remark", items = items })
	vim.cmd("copen")
end

function M.setup(opts)
	opts = opts or {}
	state.store = store.new(opts.log_path or default_log_path())
	render.setup()

	local cmd = vim.api.nvim_create_user_command
	cmd("RemarkComment", function(a)
		M.comment(a.line1, a.line2)
	end, { range = true, desc = "Comment on the selected range" })
	cmd("RemarkReply", M.user_reply, { desc = "Reply to the thread under the cursor" })
	cmd("RemarkResolve", M.resolve, { desc = "Resolve the thread under the cursor" })
	cmd("RemarkUnresolve", M.unresolve, { desc = "Reopen the thread under the cursor" })
	cmd("RemarkEdit", M.edit, { desc = "Edit your tail comment" })
	cmd("RemarkDelete", M.delete, { desc = "Delete your tail comment" })
	cmd("RemarkList", M.list, { desc = "List all threads in the quickfix list" })
	cmd("RemarkRefresh", M.refresh, { desc = "Replay the log and redraw" })
	cmd("RemarkAgentReply", function(a)
		-- :RemarkAgentReply <threadId> <body>
		local tid = a.fargs[1]
		local body = table.concat(vim.list_slice(a.fargs, 2), " ")
		if not M.reply(tid, body) then
			vim.notify("remark: agent reply rejected (unknown thread or empty body)", vim.log.levels.WARN)
		end
	end, { nargs = "+", desc = "Simulate an agent reply over the transport" })

	local group = vim.api.nvim_create_augroup("remark", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = group,
		callback = function()
			if state.store then
				M.refresh()
			end
		end,
	})

	return M
end

return M
