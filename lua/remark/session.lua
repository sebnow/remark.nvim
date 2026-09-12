-- Publishes and retracts this instance's discovery entry so an external agent
-- can find the live session and its log path (ADR 0008).
local M = {}

local uv = vim.uv or vim.loop

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
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p", tonumber("700", 8))
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

	local registry = read_registry(registry_path)
	-- Last-writer-wins: a second session on the same repo overwrites the entry.
	registry[repo_root] = { serverAddr = addr, logPath = log_path }
	write_registry(registry_path, registry)

	return addr
end

---Remove this instance's discovery entry. A missing entry is a no-op.
---@param repo_root string
---@param registry_path string? defaults to stdpath("state") .. "/remark.nvim/sessions.json"
function M.deregister(repo_root, registry_path)
	registry_path = registry_path or default_registry_path()

	local registry = read_registry(registry_path)
	if registry[repo_root] == nil then
		return
	end
	registry[repo_root] = nil
	write_registry(registry_path, registry)
end

return M
