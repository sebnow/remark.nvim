#!/usr/bin/env bash
# Run the test suite headlessly. See tests/minimal_init.lua.
set -euo pipefail
cd "$(dirname "$0")/.."
exec nvim --headless -u tests/minimal_init.lua -c "lua local ok, err = pcall(MiniTest.run); if not ok then io.stderr:write(tostring(err) .. '\n'); vim.cmd('cquit 1') end"
