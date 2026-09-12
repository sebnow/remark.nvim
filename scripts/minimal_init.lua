-- Try the plugin in a scratch session:
--   nvim -u scripts/minimal_init.lua <file>
--
-- Over a visual selection: `:'<,'>RemarkComment`
-- On a thread: `:RemarkReply`, `:RemarkResolve`, `:RemarkEdit`, `:RemarkDelete`
-- All threads: `:RemarkList`
-- Agent path: `nvim --server <addr> --remote-expr` calling
-- `v:lua.require("remark").comment_as_agent(...)` or `.reply_as_agent(...)`

local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(repo)

vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.termguicolors = true

require("remark").setup({
	-- Keep the event log in the repo so it's easy to inspect.
	log_path = repo .. "/.remark-state/log.ndjson",
})

vim.schedule(function()
	print("remark.nvim loaded; try :RemarkComment over a visual selection")
end)
