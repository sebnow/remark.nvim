-- Append-only NDJSON event log; thread state is a replay over it.

local M = {}

local Store = {}
Store.__index = Store

local uv = vim.uv or vim.loop
local uuid = require("remark.uuid")

function M.new(path)
	local self = setmetatable({}, Store)
	self.path = path
	return self
end

function Store:_append(event)
	self:_append_all({ event })
end

-- Writes every event with a single vim.fn.writefile call, which
-- open_thread_with_comment relies on to write a thread with its first comment.
function Store:_append_all(events)
	for _, event in ipairs(events) do
		event.id = event.id or uuid()
		event.ts = event.ts or uv.now()
	end
	local lines = {}
	for i, event in ipairs(events) do
		lines[i] = vim.json.encode(event)
	end
	local dir = vim.fn.fnamemodify(self.path, ":h")
	vim.fn.mkdir(dir, "p")
	vim.fn.writefile(lines, self.path, "a")
end

-- The client mints thread and comment identifiers and passes them in; the store
-- records what it is given rather than minting its own (ADR 0009).

-- commit: the revision the thread anchors to, for outdated detection.
function Store:open_thread(thread_id, file, range, commit)
	self:_append({ type = "threadOpened", threadId = thread_id, file = file, range = range, commit = commit })
end

-- Opens a thread and appends its first comment as one atomic write, so a
-- failure between the two operations (the risk open_thread + comment run as
-- separate appends) can never leave a thread durably recorded without its
-- first comment. source/meta match Store:comment's contract.
function Store:open_thread_with_comment(thread_id, comment_id, file, range, commit, source, body, meta)
	self:_append_all({
		{ type = "threadOpened", threadId = thread_id, file = file, range = range, commit = commit },
		{
			type = "commented",
			threadId = thread_id,
			commentId = comment_id,
			source = source,
			body = body,
			author = meta and meta.author,
		},
	})
end

-- source: "local" for you, "agent" for a coding agent. meta.author, when given,
-- names the agent; source stays the fixed origin label (ADR 0003).
function Store:comment(thread_id, comment_id, source, body, meta)
	self:_append({
		type = "commented",
		threadId = thread_id,
		commentId = comment_id,
		source = source,
		body = body,
		author = meta and meta.author,
	})
end

function Store:edit_comment(comment_id, body)
	self:_append({ type = "commentEdited", commentId = comment_id, body = body })
end

function Store:delete_comment(comment_id)
	self:_append({ type = "commentDeleted", commentId = comment_id })
end

-- status: resolved | unresolved | reset, all user-owned.
function Store:set_status(thread_id, status)
	self:_append({ type = status, threadId = thread_id })
end

-- Truncate the log to nothing, so a replay yields no threads. Unlike every
-- other operation this discards history rather than appending to it; it is the
-- one escape hatch from the append-only model, for starting a review over.
function Store:wipe()
	vim.fn.mkdir(vim.fn.fnamemodify(self.path, ":h"), "p")
	vim.fn.writefile({}, self.path)
end

function Store:replay()
	local threads = {}
	local order = {}
	local comment_index = {} -- commentId -> thread id

	-- Read the whole log in one call so the byte length returned as the version
	-- matches exactly the content parsed here. Stat'ing separately would race a
	-- concurrent append and report a length ahead of what was replayed (ADR 0010).
	local content = ""
	if vim.fn.filereadable(self.path) == 1 then
		local f = io.open(self.path, "rb")
		if f then
			content = f:read("*a") or ""
			f:close()
		end
	end
	local version = #content

	for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
		if line ~= "" then
			local ok, ev = pcall(vim.json.decode, line)
			if ok then
				local t = ev.type
				if t == "threadOpened" then
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
	return threads, ordered, version
end

return M
