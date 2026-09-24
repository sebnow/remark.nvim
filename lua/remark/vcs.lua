local M = {}

-- A hung git/jj process (stalled network mount, wedged hook) must not block
-- the caller forever; SystemObj:wait() force-kills and returns on expiry.
local TIMEOUT_MS = 5000

-- Returns stdout on exit 0, else nil. A missing executable counts as a
-- failure rather than an error, so a git-only machine still detects its repos.
local function run(cmd, cwd)
	local ok, proc = pcall(vim.system, cmd, { cwd = cwd, text = true })
	if not ok then
		return nil
	end
	local res = proc:wait(TIMEOUT_MS)
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

-- A directory's repo membership doesn't change within a session, so caching
-- it here (unlike M.head, which must stay fresh) turns repeated detection of
-- the same directory (e.g. one comment_as_agent call per finding in an
-- automated review pass) from a repeated subprocess spawn into a lookup.
local detect_cache = {}

-- Colocated repos report both; jujutsu wins.
function M.detect(dir)
	local cached = detect_cache[dir]
	if cached ~= nil then
		return cached or nil
	end

	local repo
	local jj = run({ "jj", "root" }, dir)
	if jj then
		repo = { vcs = "jj", root = vim.trim(jj) }
	else
		local git = run({ "git", "rev-parse", "--show-toplevel" }, dir)
		if git then
			repo = { vcs = "git", root = vim.trim(git) }
		end
	end

	detect_cache[dir] = repo or false
	return repo
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

-- A jj fileset matching exactly one workspace-relative file. A bare path is a
-- prefix glob, so one holding glob characters ("a[b].lua") would not match
-- itself.
local function root_file(rel)
	return 'root-file:"' .. rel:gsub('[\\"]', "\\%0") .. '"'
end

-- The hunks by which abspath differs between commits from and to, each as
-- { old_start, old_count, new_count } in the from-side's 1-based lines; empty
-- when the file is unchanged, nil when the diff cannot be taken. A change the
-- diff reports without hunks (a binary file) is one hunk covering every line.
function M.hunks(repo, from, to, abspath)
	local rel = relpath(repo.root, abspath)
	if not rel then
		return nil
	end
	local out
	if repo.vcs == "jj" then
		out = run({ "jj", "diff", "--git", "--context", "0", "--from", from, "--to", to, "--", root_file(rel) }, repo.root)
	else
		out = run({ "git", "diff", "--no-color", "--no-ext-diff", "-U0", from, to, "--", rel }, repo.root)
	end
	if not out then
		return nil
	end
	local hunks = {}
	for line in out:gmatch("[^\n]+") do
		local old_start, old_count, new_count = line:match("^@@ %-(%d+),?(%d*) %+%d+,?(%d*) @@")
		if old_start then
			hunks[#hunks + 1] = {
				old_start = tonumber(old_start),
				old_count = old_count == "" and 1 or tonumber(old_count),
				new_count = new_count == "" and 1 or tonumber(new_count),
			}
		end
	end
	if #hunks == 0 and vim.trim(out) ~= "" then
		hunks[1] = { old_start = 1, old_count = math.huge, new_count = 0 }
	end
	return hunks
end

-- Whether hunks touch range, the 1-based inclusive { s, e } span a thread
-- covers on the from side (ADR 0006): a hunk changes a line in the range, or
-- inserts or removes lines above it, so the range no longer points at the lines
-- the thread was written about.
function M.touches(hunks, range)
	for _, hunk in ipairs(hunks) do
		if hunk.old_count == 0 then
			-- A pure insertion lands after line old_start.
			if hunk.old_start < range.e then
				return true
			end
		else
			local last = hunk.old_start + hunk.old_count - 1
			if hunk.old_start <= range.e and last >= range.s then
				return true
			end
			if last < range.s and hunk.old_count ~= hunk.new_count then
				return true
			end
		end
	end
	return false
end

return M
