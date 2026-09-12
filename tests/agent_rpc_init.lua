-- Loads the plugin for the mini.test child Neovim used by
-- tests/test_agent_rpc.lua, standing in for the live session an external
-- agent posts into (ADR 0007). Not used by the mini.test harness itself.
local repo_root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(repo_root)

require("remark").setup({
	log_path = os.getenv("REVIEW_TEST_LOG_PATH"),
})
