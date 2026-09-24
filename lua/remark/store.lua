-- Append-only NDJSON event log; thread state is a replay over it.

local M = {}

local Store = {}
Store.__index = Store

local uv = vim.uv or vim.loop
local uuid = require("remark.uuid")
local lock = require("remark.lock")

-- Owner-only: the log records the review's comments verbatim.
local LOG_DIR_MODE = tonumber("700", 8)

function M.new(path)
	local self = setmetatable({}, Store)
	self.path = path
	return self
end

-- The maximum number of times transact re-reads and re-decides while a
-- concurrent writer keeps landing between the read and the commit. A live
-- writer holds the lock for microseconds, so contention clears at once in
-- practice; the cap only bounds a pathological storm (ADR 0010).
local MAX_ATTEMPTS = 50

-- The replayed log: the projection (by_id, ordered), the byte offset and epoch
-- it was read at (ADR 0010), and a buffer of events staged against it but not yet
-- committed. A staging method only appends to that buffer; nothing reaches the
-- log until the store commits the state. The client mints thread and comment
-- identifiers and passes them in (ADR 0009).
local State = {}
State.__index = State

-- commit: the revision the thread anchors to, for outdated detection.
function State:open_thread(thread_id, file, range, commit)
	table.insert(self._events, { type = "threadOpened", threadId = thread_id, file = file, range = range, commit = commit })
end

-- Stages the thread and its first comment together, so the commit that follows
-- writes both in one writefile call. source/meta match State:comment's contract.
function State:open_thread_with_comment(thread_id, comment_id, file, range, commit, source, body, meta)
	self:open_thread(thread_id, file, range, commit)
	self:comment(thread_id, comment_id, source, body, meta)
end

-- source: "local" for you, "agent" for a coding agent. meta.author, when given,
-- names the agent; source stays the fixed origin label (ADR 0003).
function State:comment(thread_id, comment_id, source, body, meta)
	table.insert(self._events, {
		type = "commented",
		threadId = thread_id,
		commentId = comment_id,
		source = source,
		body = body,
		author = meta and meta.author,
	})
end

function State:edit_comment(comment_id, body)
	table.insert(self._events, { type = "commentEdited", commentId = comment_id, body = body })
end

function State:delete_comment(comment_id)
	table.insert(self._events, { type = "commentDeleted", commentId = comment_id })
end

-- status: resolved | unresolved | reset, all user-owned.
function State:set_status(thread_id, status)
	table.insert(self._events, { type = status, threadId = thread_id })
end

-- The log's epoch: the id a wipe stamps on the fresh log's first line, or nil
-- for a log never wiped. The offset alone cannot tell a log from one wiped
-- and regrown to the same length; the epoch can (ADR 0010).
local function epoch_of(first_line)
	local ok, ev = pcall(vim.json.decode, first_line or "")
	if ok and type(ev) == "table" and ev.type == "logStarted" then
		return ev.id
	end
	return nil
end

local function first_line_of(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local line = f:read("*l")
	f:close()
	return line
end

local function ends_with_newline(path)
	local f = assert(io.open(path, "rb"))
	f:seek("end", -1)
	local last = f:read(1)
	f:close()
	return last == "\n"
end

-- Commits a state's staged events, but only against the log it was read from:
-- under the lock the log's current byte offset must still equal the state's, or
-- another writer has appended since and the decision may no longer hold, so
-- nothing is written and the caller must re-read (ADR 0010). Returns whether it
-- committed. The whole batch goes out in one writefile call.
-- The sidecar lock keeps two Neovim instances sharing a log (each its own OS
-- process) from interleaving writes (ADR 0002).
function Store:write(state)
	if #state._events == 0 then
		return true
	end
	local lines = {}
	local added = 0
	-- Wall-clock milliseconds since the epoch, comparable across sessions.
	local sec, usec = uv.gettimeofday()
	local now_ms = sec * 1000 + math.floor(usec / 1000)
	for i, event in ipairs(state._events) do
		event.id = event.id or uuid()
		event.ts = event.ts or now_ms
		lines[i] = vim.json.encode(event)
		added = added + #lines[i] + 1 -- writefile appends a newline per line
	end
	vim.fn.mkdir(vim.fn.fnamemodify(self.path, ":h"), "p", LOG_DIR_MODE)
	return lock(self.path .. ".lock", function()
		if math.max(vim.fn.getfsize(self.path), 0) ~= state.offset then
			return false
		end
		if state.offset > 0 and epoch_of(first_line_of(self.path)) ~= state.epoch then
			return false
		end
		-- A write cut short (disk full, a crash) can leave the last line
		-- unterminated; ending it first keeps this batch from fusing with it
		-- into one undecodable line that replay would drop along with ours.
		if state.offset > 0 and not ends_with_newline(self.path) then
			table.insert(lines, 1, "")
			added = added + 1
		end
		vim.fn.writefile(lines, self.path, "a")
		state.offset = state.offset + added
		state._events = {}
		return true
	end)
end

-- Runs a state-dependent write: replay to a current state, let decide() stage
-- events against it, and commit. If a concurrent writer appended between the
-- replay and the commit, the commit is refused and the whole sequence runs
-- again on the new state, which can turn a create into an overwrite or void a
-- target (ADR 0010, 0011). decide() runs synchronously and may run more than
-- once, so do any asynchronous prompting (a compose buffer, vim.ui.input)
-- before transact; a synchronous confirmation inside it may reappear on a
-- contended write, which ADR 0010 accepts. Returns decide()'s return value.
function Store:transact(decide)
	for _ = 1, MAX_ATTEMPTS do
		local state = self:replay()
		local result = decide(state)
		if self:write(state) then
			return result
		end
	end
	error("remark: could not commit; the log kept changing underneath the write")
end

-- Replace the log with a fresh one holding only a new epoch marker, so a
-- replay yields no threads. Unlike every other operation this discards history
-- rather than appending to it; it is the one escape hatch from the append-only
-- model, for starting a review over. The new epoch makes any state read before
-- the wipe fail to commit, even if the log regrows to that state's offset.
function Store:wipe()
	vim.fn.mkdir(vim.fn.fnamemodify(self.path, ":h"), "p", LOG_DIR_MODE)
	lock(self.path .. ".lock", function()
		vim.fn.writefile({ vim.json.encode({ type = "logStarted", id = uuid() }) }, self.path)
	end)
end

function Store:replay()
	local threads = {}
	local order = {}
	local comment_index = {} -- commentId -> thread id

	-- Read the whole log in one call so the byte offset returned on the state
	-- matches exactly the content parsed here. Stat'ing separately would race a
	-- concurrent append and report an offset ahead of what was replayed (ADR 0010).
	local content = ""
	if vim.fn.filereadable(self.path) == 1 then
		local f = io.open(self.path, "rb")
		if f then
			content = f:read("*a") or ""
			f:close()
		end
	end
	local offset = #content
	local lines = vim.split(content, "\n", { plain = true })
	local epoch = epoch_of(lines[1])

	for _, line in ipairs(lines) do
		if line ~= "" then
			-- A line that is not an event object (hand-edited, or valid JSON
			-- of another shape) is skipped like one that fails to parse.
			local ok, ev = pcall(vim.json.decode, line)
			if ok and type(ev) == "table" then
				local t = ev.type
				if t == "threadOpened" and type(ev.threadId) == "string" then
					threads[ev.threadId] = {
						id = ev.threadId,
						file = ev.file,
						range = ev.range,
						commit = ev.commit,
						status = "unresolved",
						comments = {},
					}
					table.insert(order, ev.threadId)
				elseif t == "commented" then
					local thread = threads[ev.threadId]
					if thread then
						table.insert(thread.comments, {
							id = ev.commentId,
							source = ev.source,
							body = ev.body,
							author = ev.author,
						})
						comment_index[ev.commentId] = { thread = ev.threadId }
					end
				elseif t == "commentEdited" then
					local ref = comment_index[ev.commentId]
					if ref then
						for _, c in ipairs(threads[ref.thread].comments) do
							if c.id == ev.commentId then
								c.body = ev.body
							end
						end
					end
				elseif t == "commentDeleted" then
					local ref = comment_index[ev.commentId]
					if ref then
						local thread = threads[ref.thread]
						for i, c in ipairs(thread.comments) do
							if c.id == ev.commentId then
								table.remove(thread.comments, i)
								break
							end
						end
						comment_index[ev.commentId] = nil
						-- Deleting the last comment drops the thread.
						if #thread.comments == 0 then
							threads[ref.thread] = nil
							for i, tid in ipairs(order) do
								if tid == ref.thread then
									table.remove(order, i)
									break
								end
							end
						end
					end
				elseif t == "resolved" then
					if threads[ev.threadId] then
						threads[ev.threadId].status = "resolved"
					end
				elseif t == "unresolved" or t == "reset" then
					if threads[ev.threadId] then
						threads[ev.threadId].status = "unresolved"
					end
				end
			end
		end
	end

	local ordered = {}
	for _, tid in ipairs(order) do
		if threads[tid] then
			table.insert(ordered, threads[tid])
		end
	end
	return setmetatable({ by_id = threads, ordered = ordered, offset = offset, epoch = epoch, _events = {} }, State)
end

return M
