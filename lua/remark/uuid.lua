-- UUIDv7: time-ordered, with enough random bits that instances sharing the log
-- are unlikely to collide.

local uv = vim.uv or vim.loop

local function uuid()
	local sec, usec = uv.gettimeofday()
	local ms = sec * 1000 + math.floor(usec / 1000)
	local b = {}
	for i = 6, 1, -1 do
		b[i] = ms % 256
		ms = math.floor(ms / 256)
	end
	local rand = { uv.random(10):byte(1, 10) }
	for i = 1, 10 do
		b[6 + i] = rand[i]
	end
	b[7] = (b[7] % 0x10) + 0x70 -- version 7
	b[9] = (b[9] % 0x40) + 0x80 -- variant 10xx
	local h = {}
	for i = 1, 16 do
		h[i] = string.format("%02x", b[i])
	end
	return table.concat({
		table.concat(h, "", 1, 4),
		table.concat(h, "", 5, 6),
		table.concat(h, "", 7, 8),
		table.concat(h, "", 9, 10),
		table.concat(h, "", 11, 16),
	}, "-")
end

return uuid
