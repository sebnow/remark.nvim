-- Entry points an external coding agent calls over
-- `nvim --server <addr> --remote-expr`. Kept out of remark.init so an
-- interactive session does not load agent-specific code.
local vcs = require("remark.vcs")

local M = {}

-- Wired once by remark.setup(); this module never creates its own store or
-- schedules its own redraw, so writes land in the one live session's log.
local deps = {
	store = nil,
	refresh = nil,
}

---Wire this module to the live store and the refresh callback setup()
---schedules after a write.
---@param store table
---@param refresh function
function M.setup(store, refresh)
	deps.store = store
	deps.refresh = refresh
end

-- Reads body_path as raw bytes so large, multi-line markdown with quotes and
-- backticks round-trips unchanged (no shell/Vimscript escaping involved).
local function read_body(path)
	local f = io.open(path, "r")
	if not f then
		return nil, "body_path is unreadable"
	end
	local body = f:read("*a")
	f:close()
	if body == nil or body == "" then
		return nil, "body_path is empty"
	end
	return body, nil
end

-- Runs fn, translating any error into the { ok = false, error = ... } shape so
-- an error in fn is returned to the --remote-expr caller instead of raising in
-- the editor session.
local function guarded(fn)
	local ok, result = pcall(fn)
	if not ok then
		return { ok = false, error = tostring(result) }
	end
	return result
end

-- guarded() only covers the synchronous write; by the time deps.refresh runs,
-- the caller already has its { ok = true, ... } response, so a refresh error
-- is reported here with context.
local function schedule_refresh()
	vim.schedule(function()
		local ok, err = pcall(deps.refresh)
		if not ok then
			vim.notify("remark: refresh after an agent write failed: " .. tostring(err), vim.log.levels.ERROR)
		end
	end)
end

-- A file path or display name is single-line by convention, but nothing
-- enforces that upstream (a file path can contain a literal newline; an
-- agent_name is only checked non-empty). Without this, an embedded newline
-- could forge a blank line (the block separator) and splice a fake thread
-- header into the rendered output.
local function escape_line(s)
	return (s:gsub("\n", "\\n"))
end

-- The human-facing views (render.lua, init.lua) call the reviewer's own
-- comments "you"/"local", from the reviewer's own point of view. This
-- render's audience is an external agent, not the reviewer, so it needs a
-- different word for the same origin: "user" names who the comment is
-- from, not who is looking at it.
-- Otherwise prefers the display name over the fixed origin label: author is
-- metadata for how a comment shows, source is only the fallback when none
-- was given (ADR 0003).
local function label(comment)
	if comment.source == "local" then
		return "user"
	end
	return escape_line(comment.author or comment.source)
end

-- A comment body may legitimately span multiple lines (read_body preserves
-- it verbatim); indenting continuation lines keeps that readable and keeps
-- any line inside a thread's block from being blank, so a multi-line body
-- cannot forge the block separator in unresolved_comments().
local function render_body(body)
	return (body:gsub("\n", "\n  "))
end

local function render_thread(thread)
	local lines = {
		thread.id,
		string.format("%s:%d-%d", escape_line(thread.file), thread.range.s, thread.range.e),
	}
	for _, comment in ipairs(thread.comments) do
		table.insert(lines, string.format("%s: %s", label(comment), render_body(comment.body)))
	end
	return table.concat(lines, "\n")
end

-- Agent entry point, called over --remote-expr. Renders every
-- unresolved thread as a reply handle, code location, and its comments, so an
-- agent can act on the reviewer's open threads without replaying the NDJSON
-- log itself. Read-only: it cannot resolve, reopen, or reset a thread (ADR
-- 0004).
---@return string
function M.unresolved_comments()
	local ok, result = pcall(function()
		local _, ordered = deps.store:replay()
		local blocks = {}
		for _, thread in ipairs(ordered) do
			if thread.status == "unresolved" then
				-- A single malformed thread (a hand-edited or
				-- schema-drifted log entry) fails on its own render
				-- rather than blanking out every other thread's output.
				local render_ok, rendered = pcall(render_thread, thread)
				if render_ok then
					table.insert(blocks, rendered)
				else
					vim.notify(
						"remark: failed to render thread " .. tostring(thread.id) .. ": " .. tostring(rendered),
						vim.log.levels.ERROR
					)
				end
			end
		end
		return table.concat(blocks, "\n\n")
	end)
	if not ok then
		-- The RPC contract returns "" here, as for "no unresolved threads",
		-- so report the failure in the reviewer's session.
		vim.notify("remark: unresolved_comments failed: " .. tostring(result), vim.log.levels.ERROR)
		return ""
	end
	return result
end

-- Agent entry point, called over --remote-expr. Opens a new thread
-- and appends its first comment as the named agent; never reaches user-owned
-- status or comment edit/delete (ADR 0004).
---@param agent_name string
---@param file string
---@param line_start integer
---@param line_end integer
---@param body_path string
---@return { ok: boolean, error?: string, thread_id?: string }
function M.comment_as_agent(agent_name, file, line_start, line_end, body_path)
	return guarded(function()
		if agent_name == nil or agent_name == "" then
			return { ok = false, error = "agent_name is required" }
		end
		if type(file) ~= "string" or vim.fn.filereadable(file) ~= 1 then
			return { ok = false, error = "file is unreadable" }
		end
		if type(line_start) ~= "number" or type(line_end) ~= "number" or line_start < 1 or line_end < line_start then
			return { ok = false, error = "invalid line range" }
		end
		local body, body_err = read_body(body_path)
		if not body then
			return { ok = false, error = body_err }
		end

		local range = { s = line_start, e = line_end }
		local repo = vcs.detect(vim.fn.fnamemodify(file, ":h"))
		local commit = repo and vcs.head(repo)
		local thread_id = deps.store:open_thread_with_comment(file, range, commit, "agent", body, {
			author = agent_name,
		})
		schedule_refresh()
		return { ok = true, thread_id = thread_id }
	end)
end

-- Agent entry point, called over --remote-expr. Appends a reply to
-- an existing thread as the named agent; never reaches user-owned status or
-- comment edit/delete (ADR 0004).
---@param agent_name string
---@param thread_id string
---@param body_path string
---@return { ok: boolean, error?: string }
function M.reply_as_agent(agent_name, thread_id, body_path)
	return guarded(function()
		if agent_name == nil or agent_name == "" then
			return { ok = false, error = "agent_name is required" }
		end
		local by_id = deps.store:replay()
		if not by_id[thread_id] then
			return { ok = false, error = "unknown thread_id" }
		end
		local body, body_err = read_body(body_path)
		if not body then
			return { ok = false, error = body_err }
		end

		deps.store:comment(thread_id, "agent", body, { author = agent_name })
		schedule_refresh()
		return { ok = true }
	end)
end

return M
