local uuid = require("remark.uuid")

local T = MiniTest.new_set()

T["generates a 36-char hyphenated UUID"] = function()
	local id = uuid()
	MiniTest.expect.equality(#id, 36)
	MiniTest.expect.equality(id:sub(9, 9), "-")
	MiniTest.expect.equality(id:sub(14, 14), "-")
	MiniTest.expect.equality(id:sub(19, 19), "-")
	MiniTest.expect.equality(id:sub(24, 24), "-")
end

T["encodes version 7 and the RFC 4122 variant"] = function()
	local id = uuid()
	MiniTest.expect.equality(id:sub(15, 15), "7")
	MiniTest.expect.equality(id:sub(20, 20):match("[89ab]") ~= nil, true)
end

T["is time-ordered: later ids sort after earlier ones"] = function()
	local first = uuid()
	vim.uv.sleep(2)
	local second = uuid()
	MiniTest.expect.equality(first < second, true)
end

T["does not repeat within a millisecond"] = function()
	MiniTest.expect.equality(uuid() ~= uuid(), true)
end

return T
