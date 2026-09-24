-- Publishes and retracts this instance's discovery entry so an external agent
-- can find the live session and its log path (ADR 0008).
local M = {}

local uv = vim.uv or vim.loop
local lock = require("remark.lock")

-- The registry's path is itself part of the discovery contract: an agent
-- reads this file directly, under the plugin's state directory, to reach a
-- session (ADR 0008). register()/deregister() accept an override so callers
-- (setup(), tests) don't have to redirect stdpath("state") itself to control
-- where it lives.
local function default_registry_path()
	return vim.fn.stdpath("state") .. "/remark.nvim/sessions.json"
end

local function read_registry(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

-- Owner-only: the registry publishes an unauthenticated --remote-expr address,
-- so a world-readable file would let any other local user read it and reach
-- that channel too. The content goes to an owner-only temporary file renamed
-- over the registry, so the registry is written owner-only and a reader never
-- sees a half-written file.
local function write_registry(path, registry)
	local tmp = path .. ".tmp"
	local fd = assert(uv.fs_open(tmp, "w", tonumber("600", 8)))
	-- An existing temporary file keeps its old mode through the open.
	uv.fs_fchmod(fd, tonumber("600", 8))
	local ok, err = uv.fs_write(fd, vim.json.encode(registry) .. "\n")
	uv.fs_close(fd)
	if not ok then
		uv.fs_unlink(tmp)
		error("remark: could not write the session registry: " .. tostring(err))
	end
	assert(uv.fs_rename(tmp, path))
end

-- Sessions on different repos share one registry, so each read-modify-write
-- runs under a lock; otherwise two sessions starting together could each drop
-- the other's entry. change returns whether it modified the registry.
local function update_registry(path, change)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p", tonumber("700", 8))
	lock(path .. ".lock", function()
		local registry = read_registry(path)
		if change(registry) then
			write_registry(path, registry)
		end
	end)
end

---Register the running instance for discovery. Ensures a server address exists,
---then records this session's server address and log path keyed by repo root.
---Returns the server address an agent should target.
---@param repo_root string
---@param log_path string
---@param registry_path string? defaults to stdpath("state") .. "/remark.nvim/sessions.json"
---@return string server_addr
function M.register(repo_root, log_path, registry_path)
	registry_path = registry_path or default_registry_path()

	local addr = vim.v.servername
	if addr == "" then
		addr = vim.fn.serverstart()
	end

	update_registry(registry_path, function(registry)
		-- Last-writer-wins: a second session on the same repo overwrites the entry.
		registry[repo_root] = { serverAddr = addr, logPath = log_path }
		return true
	end)

	return addr
end

---Remove this instance's discovery entry. A missing entry, or one a later
---session on the same repo has since taken over, is left alone.
---@param repo_root string
---@param registry_path string? defaults to stdpath("state") .. "/remark.nvim/sessions.json"
function M.deregister(repo_root, registry_path)
	registry_path = registry_path or default_registry_path()

	update_registry(registry_path, function(registry)
		local entry = registry[repo_root]
		if type(entry) ~= "table" or entry.serverAddr ~= vim.v.servername then
			return false
		end
		registry[repo_root] = nil
		return true
	end)
end

return M
