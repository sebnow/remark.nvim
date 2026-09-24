local remark = require("remark")
local store = require("remark.store")
local uuid = require("remark.uuid")

local log_path

-- Counts the VCS subprocesses fn spawns.
local function count_spawns(fn)
	local calls = 0
	local orig_system = vim.system
	vim.system = function(cmd, opts)
		calls = calls + 1
		return orig_system(cmd, opts)
	end
	local ok, err = pcall(fn)
	vim.system = orig_system
	assert(ok, err)
	return calls
end

-- A file committed in a fresh git repo, shown in the current buffer.
local function show_committed_file()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local file = dir .. "/f.lua"
	vim.fn.writefile({ "one", "two", "three" }, file)
	vim.system({ "git", "init", "-q" }, { cwd = dir }):wait()
	vim.system({ "git", "add", "f.lua" }, { cwd = dir }):wait()
	vim.system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c" }, { cwd = dir }):wait()
	local head = vim.trim(vim.system({ "git", "rev-parse", "HEAD" }, { cwd = dir, text = true }):wait().stdout)
	vim.cmd.edit(file)
	return file, head
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			log_path = vim.fn.tempname() .. "/log.ndjson"
			remark.setup({
				log_path = log_path,
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

T["spawns no VCS process for a buffer without anchored threads"] = function()
	show_committed_file()

	MiniTest.expect.equality(count_spawns(remark.refresh), 0)
end

T["diffs a shared anchor once however many threads use it"] = function()
	local file, head = show_committed_file()
	store.new(log_path):transact(function(snap)
		for line = 1, 3 do
			snap:open_thread_with_comment(uuid(), uuid(), file, { s = line, e = line }, head, "local", "x")
		end
	end)
	remark.refresh()

	-- One for the head, one for the diff; detection is cached by now.
	MiniTest.expect.equality(count_spawns(remark.refresh), 2)
end

return T
