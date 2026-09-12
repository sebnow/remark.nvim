-- Canary for the test harness itself: if the runtimepath wiring in
-- tests/minimal_init.lua breaks, this fails before any real suite does.
local T = MiniTest.new_set()

T["loads the plugin module"] = function()
	MiniTest.expect.equality(type(require("remark")), "table")
end

return T
