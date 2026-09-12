local M = {}

-- Returns stdout on exit 0, else nil.
local function run(cmd, cwd)
	local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
	if res.code ~= 0 then
		return nil
	end
	return res.stdout
end

-- nil when abspath sits outside root.
local function relpath(root, abspath)
	root = root:gsub("/*$", "")
	if abspath:sub(1, #root + 1) == root .. "/" then
		return abspath:sub(#root + 2)
	end
	return nil
end

-- Colocated repos report both; jujutsu wins.
function M.detect(dir)
	local jj = run({ "jj", "root" }, dir)
	if jj then
		return { vcs = "jj", root = vim.trim(jj) }
	end
	local git = run({ "git", "rev-parse", "--show-toplevel" }, dir)
	if git then
		return { vcs = "git", root = vim.trim(git) }
	end
	return nil
end

-- The commit a new comment anchors to.
function M.head(repo)
	local id
	if repo.vcs == "jj" then
		id = run({ "jj", "log", "-r", "@", "--no-graph", "-T", "commit_id" }, repo.root)
	else
		id = run({ "git", "rev-parse", "HEAD" }, repo.root)
	end
	return id and vim.trim(id) or nil
end

-- Whether abspath changed between commits from and to.
function M.changed(repo, from, to, abspath)
	local rel = relpath(repo.root, abspath)
	if not rel then
		return false
	end
	local out
	if repo.vcs == "jj" then
		out = run({ "jj", "diff", "--from", from, "--to", to, "--name-only", "--", rel }, repo.root)
	else
		out = run({ "git", "diff", "--name-only", from, to, "--", rel }, repo.root)
	end
	return out ~= nil and vim.trim(out) ~= ""
end

return M
