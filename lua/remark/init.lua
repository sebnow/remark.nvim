local store = require("remark.store")
local render = require("remark.render")
local vcs = require("remark.vcs")
local session = require("remark.session")
local agent = require("remark.agent")
local uuid = require("remark.uuid")

local M = {}

local state = {
	store = nil,
	by_id = {}, -- threadId -> thread
	repo_root = nil, -- the key session discovery registers under
	registry_path = nil, -- passed to session.register()/deregister()
}

-- The log lives under the plugin's state directory, not in the repo under
-- review, so a review leaves no artifact in the tree it comments on (ADR 0008).
-- It is keyed per repo root so sessions on different repos keep separate logs;
-- the root is hashed to a fixed-length, filesystem-safe name that stays within
-- path limits.
local function default_log_path(repo_root)
	local key = repo_root or vim.fn.getcwd()
	return vim.fn.stdpath("state") .. "/remark.nvim/logs/" .. vim.fn.sha256(key) .. ".ndjson"
end

function M.refresh()
	local snap = state.store:replay()
	state.by_id = snap.by_id
	local ordered = snap.ordered
	local bufnr = vim.api.nvim_get_current_buf()
	-- Only real file buffers carry threads. A special buffer (our own compose
	-- buffer, a terminal, quickfix) has a name that is not a path; deriving a
	-- vcs cwd from it would spawn git in a directory that does not exist.
	if vim.bo[bufnr].buftype ~= "" then
		return 0
	end
	local file = vim.api.nvim_buf_get_name(bufnr)
	local anchored = {}
	for _, t in ipairs(ordered) do
		if t.file == file and t.commit then
			anchored[#anchored + 1] = t
		end
	end
	-- Refresh runs on every buffer switch and each VCS call is a blocking
	-- subprocess, so a buffer with no anchored threads spawns none, and threads
	-- sharing an anchor share one diff.
	local repo = #anchored > 0 and vcs.detect(vim.fn.fnamemodify(file, ":h")) or nil
	local head = repo and vcs.head(repo)
	if head then
		local hunks_by_anchor = {}
		for _, t in ipairs(anchored) do
			local hunks = hunks_by_anchor[t.commit]
			if hunks == nil then
				hunks = vcs.hunks(repo, t.commit, head, t.file) or false
				hunks_by_anchor[t.commit] = hunks
			end
			t.outdated = hunks and vcs.touches(hunks, t.range) or false
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

local function comment_by_id(thread, comment_id)
	for _, c in ipairs(thread.comments) do
		if c.id == comment_id then
			return c
		end
	end
	return nil
end

-- After a mutation made from inside a float: refresh so state and the gutter
-- reflect it, then rebuild the thread's buffer so the open float updates in
-- place, or close the float if the thread is gone (its last comment deleted).
local function after_mutation(thread_id)
	M.refresh()
	local thread = state.by_id[thread_id]
	if thread then
		render.refresh_float(thread)
	else
		render.close_float()
	end
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
	-- A thread anchors to a file on disk; a special or unnamed buffer has none,
	-- so a thread recorded there could never be shown again.
	if vim.bo[bufnr].buftype ~= "" or file == "" then
		vim.notify("remark: comments attach to files; this buffer is not one", vim.log.levels.WARN)
		return
	end
	local range = command_range(opts)
	local repo = vcs.detect(vim.fn.fnamemodify(file, ":h"))
	local commit = repo and vcs.head(repo)
	local tid, cid = uuid(), uuid()
	render.compose({
		id = tid,
		title = "comment: :w or <C-s> to submit, q to cancel",
		on_submit = function(body)
			state.store:transact(function(snap)
				-- A draft kept after a failed submit carries ids that may
				-- already be recorded; submitting it again is a retry (ADR 0011).
				if not snap.by_id[tid] then
					snap:open_thread(tid, file, range, commit)
					snap:comment(tid, cid, "local", body)
				end
			end)
			M.refresh()
		end,
	})
end

-- Accepts a thread so the in-float keymap can reply to the thread it is showing;
-- the command passes none and falls back to the thread under the cursor.
function M.user_reply(thread)
	thread = thread or thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	local cid = uuid()
	render.compose({
		id = cid,
		title = "reply: :w or <C-s> to submit, q to cancel",
		on_submit = function(body)
			state.store:transact(function(snap)
				local cur = snap.by_id[thread.id]
				if cur and not comment_by_id(cur, cid) then
					snap:comment(thread.id, cid, "local", body)
				end
			end)
			M.refresh()
		end,
	})
end

local function set_status(status)
	local thread = thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	state.store:transact(function(snap)
		if snap.by_id[thread.id] then
			snap:set_status(thread.id, status)
		end
	end)
	M.refresh()
end

function M.resolve()
	set_status("resolved")
end

function M.unresolve()
	set_status("unresolved")
end

-- Ours to mutate: the last comment we authored, even if an agent replied after
-- it. source=="local" stands in for "authored by us"; theirs is
-- read-only, like editing a read-only file.
local function last_our_comment(thread)
	for i = #thread.comments, 1, -1 do
		if thread.comments[i].source == "local" then
			return thread.comments[i]
		end
	end
	return nil
end

function M.edit()
	local thread = thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	local c = last_our_comment(thread)
	if not c then
		vim.notify("remark: no comment of yours here; theirs is read-only", vim.log.levels.WARN)
		return
	end
	render.compose({
		id = c.id,
		title = "edit: :w or <C-s> to submit, q to cancel",
		default = c.body,
		on_submit = function(body)
			state.store:transact(function(snap)
				local cur = snap.by_id[thread.id]
				local mine = cur and last_our_comment(cur)
				if mine and mine.id == c.id then
					snap:edit_comment(c.id, body)
				end
			end)
			M.refresh()
		end,
	})
end

function M.delete()
	local thread = thread_at_cursor()
	if not thread then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	local c = last_our_comment(thread)
	if not c then
		vim.notify("remark: no comment of yours here; theirs is read-only", vim.log.levels.WARN)
		return
	end
	state.store:transact(function(snap)
		local cur = snap.by_id[thread.id]
		local mine = cur and last_our_comment(cur)
		if mine and mine.id == c.id then
			snap:delete_comment(c.id)
		end
	end)
	M.refresh()
end

-- Edit the specific comment under the cursor in a thread float. Ownership is
-- enforced here: theirs is read-only, like editing a read-only file.
function M.edit_here(thread, fbuf)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local meta = render.comment_at(fbuf, lnum)
	if not meta then
		vim.notify("remark: no comment here", vim.log.levels.WARN)
		return
	end
	if meta.source ~= "local" then
		vim.notify("remark: that comment is theirs and read-only", vim.log.levels.WARN)
		return
	end
	local c = comment_by_id(thread, meta.id)
	render.compose({
		id = meta.id,
		title = "edit: :w or <C-s> to submit, q to cancel",
		default = c and c.body or "",
		on_submit = function(body)
			state.store:transact(function(snap)
				local cur = snap.by_id[thread.id]
				local target = cur and comment_by_id(cur, meta.id)
				if target and target.source == "local" then
					snap:edit_comment(meta.id, body)
				end
			end)
			after_mutation(thread.id)
		end,
	})
end

function M.delete_here(thread, fbuf)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local meta = render.comment_at(fbuf, lnum)
	if not meta then
		vim.notify("remark: no comment here", vim.log.levels.WARN)
		return
	end
	if meta.source ~= "local" then
		vim.notify("remark: that comment is theirs and read-only", vim.log.levels.WARN)
		return
	end
	state.store:transact(function(snap)
		local cur = snap.by_id[thread.id]
		local target = cur and comment_by_id(cur, meta.id)
		if target and target.source == "local" then
			snap:delete_comment(meta.id)
		end
	end)
	after_mutation(thread.id)
end

-- Open the thread under the cursor in a focused, interactive float: r to reply,
-- e to edit and D to delete the comment under the cursor, z to zoom, q to close.
-- Disambiguates when more than one thread covers the line.
function M.open()
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local ids = render.threads_at(bufnr, lnum)
	if #ids == 0 then
		vim.notify("remark: no thread under cursor", vim.log.levels.WARN)
		return
	end
	local function present(tid)
		local thread = state.by_id[tid]
		local fwin = render.show_thread(thread, win, true)
		local fbuf = vim.api.nvim_win_get_buf(fwin)
		vim.keymap.set("n", "r", function()
			M.user_reply(thread)
		end, { buffer = fbuf, desc = "remark: reply" })
		vim.keymap.set("n", "e", function()
			M.edit_here(thread, fbuf)
		end, { buffer = fbuf, desc = "remark: edit comment under cursor" })
		vim.keymap.set("n", "D", function()
			M.delete_here(thread, fbuf)
		end, { buffer = fbuf, desc = "remark: delete comment under cursor" })
		vim.keymap.set("n", "z", render.zoom, { buffer = fbuf, desc = "remark: zoom" })
		vim.keymap.set("n", "q", render.close_float, { buffer = fbuf, desc = "remark: close" })
	end
	if #ids == 1 then
		present(ids[1])
	else
		vim.ui.select(ids, {
			prompt = "Thread:",
			format_item = function(id)
				local first = state.by_id[id].comments[1]
				return string.format("%s: %s", first and first.source or "?", first and first.body or "")
			end,
		}, function(choice)
			if choice then
				present(choice)
			end
		end)
	end
end

-- A read-only overview of every thread on the line, backing :RemarkHover.
-- Left alone when the user has stepped into an interactive float. Not wired to
-- CursorHold by default; the README shows the recipe for users who want that.
function M.hover()
	if render.is_float_focused() then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local ids = render.threads_at(bufnr, lnum)
	if #ids == 0 then
		return
	end
	local threads = {}
	for _, id in ipairs(ids) do
		threads[#threads + 1] = state.by_id[id]
	end
	render.show_overview(threads, win, lnum - 1)
end

-- The threads in log order, exactly as the store replays them. This is the seam
-- a picker builds its entries from; presentation stays with the consumer.
function M.threads()
	return state.store:replay().ordered
end

-- One quickfix entry per thread, formatted here so :RemarkList owns its own
-- presentation and the raw threads stay untouched for other consumers.
function M.list()
	local items = {}
	for _, t in ipairs(M.threads()) do
		local marker = t.status == "resolved" and "✓" or "●"
		local first = t.comments[1]
		local who = first and (first.source == "local" and "you" or first.author or first.source) or "?"
		-- A quickfix entry is one line; the body's first line stands for it.
		local body = first and first.body or ""
		local first_line = body:match("^[^\n]*")
		if first_line ~= body then
			body = first_line .. " …"
		end
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
	-- The default log path is keyed off the resolved repo root, so detect it
	-- before resolving the path.
	local repo = vcs.detect(vim.fn.getcwd())
	state.repo_root = repo and repo.root
	local log_path = opts.log_path or default_log_path(state.repo_root)
	state.store = store.new(log_path)
	render.setup()
	agent.setup(state.store, M.refresh)

	-- Discovery publishes whatever log path was just resolved, default or
	-- override (ADR 0008).
	state.registry_path = opts.registry_path
	if state.repo_root then
		session.register(state.repo_root, log_path, state.registry_path)
	end

	local cmd = vim.api.nvim_create_user_command
	cmd("RemarkComment", M.comment, { range = true, desc = "Comment on the selected range" })
	-- Wrapped so the command's opts table is not taken for the thread argument
	-- M.user_reply accepts from the in-float keymap.
	cmd("RemarkReply", function()
		M.user_reply()
	end, { desc = "Reply to the thread under the cursor" })
	cmd("RemarkOpen", M.open, { desc = "Open the thread under the cursor interactively" })
	cmd("RemarkHover", M.hover, { desc = "Preview the threads on the line in a float" })
	cmd("RemarkResolve", M.resolve, { desc = "Resolve the thread under the cursor" })
	cmd("RemarkUnresolve", M.unresolve, { desc = "Reopen the thread under the cursor" })
	cmd("RemarkEdit", M.edit, { desc = "Edit your last comment" })
	cmd("RemarkDelete", M.delete, { desc = "Delete your last comment" })
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
	-- A hover preview opened by :RemarkHover closes on the next move, unless the
	-- user has stepped into it (an interactive :RemarkOpen).
	vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
		group = group,
		callback = function()
			if not render.is_float_focused() then
				render.close_float()
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
