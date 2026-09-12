local remark = require("remark")

local function run(cmd, cwd)
	return vim.system(cmd, { cwd = cwd, text = true }):wait()
end

local function init_git_repo()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	run({ "git", "init", "-q" }, dir)
	local root = vim.trim(run({ "git", "rev-parse", "--show-toplevel" }, dir).stdout)
	return root
end

local function read_registry(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local original_cwd

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			original_cwd = vim.fn.getcwd()
		end,
		post_case = function()
			vim.fn.chdir(original_cwd)
		end,
	},
})

T["setup() registers the session for the resolved repo and log path, at the given registry_path"] = function()
	local repo_root = init_git_repo()
	vim.fn.chdir(repo_root)
	local log_path = vim.fn.tempname() .. "/log.ndjson"
	local registry_path = vim.fn.tempname() .. "/sessions.json"

	remark.setup({ log_path = log_path, registry_path = registry_path })

	local entry = read_registry(registry_path)[repo_root]
	MiniTest.expect.equality(entry.logPath, log_path)
	MiniTest.expect.equality(entry.serverAddr, vim.v.servername)
end

T["setup() registers whatever log_path it resolved"] = function()
	local repo_root = init_git_repo()
	vim.fn.chdir(repo_root)
	local registry_path = vim.fn.tempname() .. "/sessions.json"
	-- No log_path override: setup falls back to its own default_log_path(),
	-- which the registry must still publish unchanged (ADR 0008: no branch on
	-- origin).
	remark.setup({ registry_path = registry_path })

	local entry = read_registry(registry_path)[repo_root]
	MiniTest.expect.equality(entry.logPath, repo_root .. "/.remark-state/log.ndjson")
end

T["VimLeave deregisters the session"] = function()
	local repo_root = init_git_repo()
	vim.fn.chdir(repo_root)
	local log_path = vim.fn.tempname() .. "/log.ndjson"
	local registry_path = vim.fn.tempname() .. "/sessions.json"
	remark.setup({ log_path = log_path, registry_path = registry_path })
	MiniTest.expect.equality(read_registry(registry_path)[repo_root] ~= nil, true)

	vim.api.nvim_exec_autocmds("VimLeave", { group = "remark" })

	MiniTest.expect.equality(read_registry(registry_path)[repo_root], nil)
end

return T
