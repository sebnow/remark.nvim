-- Cross-process mutual exclusion over a sidecar file, via flock(2). The kernel
-- releases a flock when its holder exits, so a crashed holder leaves no stale
-- lock behind. Advisory: only remark honours it.

local uv = vim.uv or vim.loop

local has_ffi, ffi = pcall(require, "ffi")
if has_ffi then
	pcall(ffi.cdef, "int flock(int fd, int operation);")
end

-- The same values on Linux and the BSDs, macOS included.
local LOCK_EX, LOCK_NB, LOCK_UN = 2, 4, 8

-- A live holder releases in microseconds (it guards a yield-free write), so
-- contention clears almost immediately; the deadline only bounds a holder that
-- is alive but wedged.
local RETRY_MS = 5
local DEADLINE_MS = 2000

---Run fn while holding an exclusive lock on lockpath, creating the file if it
---is missing. The file's directory must already exist. Raises if the lock
---cannot be taken before the deadline; re-raises fn's error after releasing.
---@param lockpath string
---@param fn function
return function(lockpath, fn)
	if not has_ffi then
		error("remark: taking the log lock needs a LuaJIT build of Neovim")
	end
	local fd = assert(uv.fs_open(lockpath, "w", tonumber("600", 8)))
	local deadline = uv.hrtime() + DEADLINE_MS * 1e6
	while ffi.C.flock(fd, LOCK_EX + LOCK_NB) ~= 0 do
		if uv.hrtime() >= deadline then
			uv.fs_close(fd)
			error("remark: could not acquire the lock at " .. lockpath)
		end
		uv.sleep(RETRY_MS)
	end
	local ok, result = pcall(fn)
	ffi.C.flock(fd, LOCK_UN)
	uv.fs_close(fd)
	if not ok then
		error(result, 0)
	end
	return result
end
