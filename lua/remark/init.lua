local store = require("remark.store")
local render = require("remark.render")
local vcs = require("remark.vcs")
local session = require("remark.session")
local agent = require("remark.agent")

local M = {}

local state = {
	store = nil,
	by_id = {}, -- threadId -> thread
	repo_root = nil, -- the key session discovery registers under
	registry_path = nil, -- passed to session.register()/deregister()
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

-- The line span a range command targets. opts.range is the command-args count
-- (0, 1, or 2): a caller who gave a range (a visual selection, or an explicit
-- `:a,bRemarkComment`) sets it above 0 and fills line1/line2. When it is 0 the
-- command still defaults line1/line2 to the cursor line, but a direct Lua call
-- (`require("remark").comment()`) passes no opts at all, so resolve the cursor
-- line here rather than trusting line1/line2 to be present.
local function command_range(opts)
	if opts.range and opts.range > 0 then
		return { s = math.min(opts.line1, opts.line2), e = math.max(opts.line1, opts.line2) }
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	return { s = lnum, e = lnum }
end

function M.comment(opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()
	local file = vim.api.nvim_buf_get_name(bufnr)
	local range = command_range(opts)
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

-- The threads in log order, exactly as the store replays them. This is the seam
-- a picker builds its entries from; presentation stays with the consumer.
function M.threads()
	local _, ordered = state.store:replay()
	return ordered
end

-- One quickfix entry per thread, formatted here so :RemarkList owns its own
-- presentation and the raw threads stay untouched for other consumers.
function M.list()
	local items = {}
	for _, t in ipairs(M.threads()) do
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

-- Discards the whole log. Destructive and irreversible, so it confirms first;
-- a bang (:RemarkWipe!) skips the prompt, the way :q! skips Vim's.
function M.wipe(opts)
	opts = opts or {}
	if not opts.bang then
		local choice = vim.fn.confirm("remark: wipe all threads? This cannot be undone.", "&Yes\n&No", 2)
		if choice ~= 1 then
			return
		end
	end
	state.store:wipe()
	M.refresh()
end

function M.setup(opts)
	opts = opts or {}
	local log_path = opts.log_path or default_log_path()
	state.store = store.new(log_path)
	render.setup()
	agent.setup(state.store, M.refresh)

	-- Discovery publishes whatever log path was just resolved, default or
	-- override (ADR 0008).
	local repo = vcs.detect(vim.fn.getcwd())
	state.repo_root = repo and repo.root
	state.registry_path = opts.registry_path
	if state.repo_root then
		session.register(state.repo_root, log_path, state.registry_path)
	end

	local cmd = vim.api.nvim_create_user_command
	cmd("RemarkComment", M.comment, { range = true, desc = "Comment on the selected range" })
	cmd("RemarkReply", M.user_reply, { desc = "Reply to the thread under the cursor" })
	cmd("RemarkResolve", M.resolve, { desc = "Resolve the thread under the cursor" })
	cmd("RemarkUnresolve", M.unresolve, { desc = "Reopen the thread under the cursor" })
	cmd("RemarkEdit", M.edit, { desc = "Edit your tail comment" })
	cmd("RemarkDelete", M.delete, { desc = "Delete your tail comment" })
	cmd("RemarkList", M.list, { desc = "List all threads in the quickfix list" })
	cmd("RemarkWipe", M.wipe, { bang = true, desc = "Wipe all threads (! to skip the prompt)" })
	cmd("RemarkRefresh", M.refresh, { desc = "Replay the log and redraw" })

	local group = vim.api.nvim_create_augroup("remark", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = group,
		callback = function()
			if state.store then
				M.refresh()
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeave", {
		group = group,
		callback = function()
			if state.repo_root then
				session.deregister(state.repo_root, state.registry_path)
			end
		end,
	})

	return M
end

return M
