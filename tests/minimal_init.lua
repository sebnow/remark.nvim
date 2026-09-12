-- Test-only entry point: puts the plugin and mini.test on the runtimepath,
-- then hands control to MiniTest.run() (see scripts/test.sh).
local repo_root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(repo_root)

-- mini.test comes from the nix devShell rather than a vendored copy (ADR 0007).
local mini_nvim_rtp = os.getenv("MINI_NVIM_RTP")
if not mini_nvim_rtp then
	error("MINI_NVIM_RTP is unset; run tests inside the project's nix devShell (`nix develop`)")
end
vim.opt.runtimepath:append(mini_nvim_rtp)

require("mini.test").setup()
