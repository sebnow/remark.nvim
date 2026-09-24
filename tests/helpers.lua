-- Shared by test files; mini.test only collects tests/test_*.lua, so this is not run as one.
local M = {}

-- Takes an flock on lockpath in a separate Neovim process and holds it for
-- hold_ms, standing in for another instance mid-write. Returns once the lock is
-- held; wait on the returned process to know it has been released.
function M.hold_lock_in_child(lockpath, hold_ms)
	local locked = vim.fn.tempname()
	local script = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({
		'local ffi = require("ffi")',
		'ffi.cdef("int flock(int fd, int operation);")',
		string.format("local fd = vim.uv.fs_open(%q, 'w', 384)", lockpath),
		"assert(ffi.C.flock(fd, 2) == 0)",
		string.format("vim.fn.writefile({}, %q)", locked),
		string.format("vim.uv.sleep(%d)", hold_ms),
	}, script)
	local proc = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script })
	assert(vim.wait(5000, function()
		return vim.fn.filereadable(locked) == 1
	end, 10), "child never took the lock")
	return proc
end

return M
