-- Publishes and retracts this instance's discovery entry so an external agent
-- can find the live session and its log path (ADR 0008).
local M = {}

-- The registry's path is itself part of the discovery contract: an agent
-- reads this file directly, under the plugin's state directory, to reach a
-- session (ADR 0008).
local function registry_path()
	return vim.fn.stdpath("state") .. "/remark.nvim/sessions.json"
end

local function read_registry()
	local path = registry_path()
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

local function write_registry(registry)
	local path = registry_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	vim.fn.writefile({ vim.json.encode(registry) }, path)
end

---Register the running instance for discovery. Ensures a server address exists,
---then records this session's server address and log path keyed by repo root.
---Returns the server address an agent should target.
---@param repo_root string
---@param log_path string
---@return string server_addr
function M.register(repo_root, log_path)
	local addr = vim.v.servername
	if addr == "" then
		addr = vim.fn.serverstart()
	end

	local registry = read_registry()
	-- Last-writer-wins: a second session on the same repo overwrites the entry.
	registry[repo_root] = { serverAddr = addr, logPath = log_path }
	write_registry(registry)

	return addr
end

---Remove this instance's discovery entry. A missing entry is a no-op.
---@param repo_root string
function M.deregister(repo_root)
	local registry = read_registry()
	if registry[repo_root] == nil then
		return
	end
	registry[repo_root] = nil
	write_registry(registry)
end

return M
