-- <Plug> mappings expose remark.nvim's actions as named, key-less handles the
-- user binds their own keys to (with remap = true). They live in plugin/ so they
-- exist at startup before user config maps keys to them; the action bodies stay
-- in the commands that require("remark").setup() creates, so requiring the
-- module is deferred until an action fires.
if vim.g.loaded_remark then
	return
end
vim.g.loaded_remark = true

-- Normal mode gives no range, so RemarkComment falls back to the cursor line.
vim.keymap.set("n", "<Plug>(RemarkComment)", "<Cmd>RemarkComment<CR>", { silent = true, desc = "Comment on the current line" })
-- A ':' right-hand side in visual mode makes Vim prefix the '<,'> range, so the
-- command receives the selection as its line range. <Cmd> would not.
vim.keymap.set("x", "<Plug>(RemarkComment)", ":RemarkComment<CR>", { silent = true, desc = "Comment on the selection" })

vim.keymap.set("n", "<Plug>(RemarkReply)", "<Cmd>RemarkReply<CR>", { silent = true, desc = "Reply to the thread under the cursor" })
vim.keymap.set("n", "<Plug>(RemarkResolve)", "<Cmd>RemarkResolve<CR>", { silent = true, desc = "Resolve the thread under the cursor" })
vim.keymap.set("n", "<Plug>(RemarkUnresolve)", "<Cmd>RemarkUnresolve<CR>", { silent = true, desc = "Reopen the thread under the cursor" })
vim.keymap.set("n", "<Plug>(RemarkEdit)", "<Cmd>RemarkEdit<CR>", { silent = true, desc = "Edit your tail comment" })
vim.keymap.set("n", "<Plug>(RemarkDelete)", "<Cmd>RemarkDelete<CR>", { silent = true, desc = "Delete your tail comment" })
vim.keymap.set("n", "<Plug>(RemarkList)", "<Cmd>RemarkList<CR>", { silent = true, desc = "List all threads in the quickfix list" })
