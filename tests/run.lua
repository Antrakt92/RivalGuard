local root = arg[1] or "."
local H = assert(loadfile(root .. "/tests/support/harness.lua"))()
H.root = root
_G.RGTest = H

if #arg < 2 then
    assert(loadfile(root .. "/tests/test_core.lua"))()
else
    for index = 2, #arg do assert(loadfile(root .. "/" .. arg[index]))() end
end

local failed = 0
for _, test in ipairs(H.tests) do
    local ok, err = xpcall(test.fn, debug.traceback)
    if ok then
        io.write("PASS ", test.name, "\n")
    else
        failed = failed + 1
        io.stderr:write("FAIL ", test.name, "\n", tostring(err), "\n")
    end
end
io.write(string.format("%d tests, %d assertions, %d failures\n", #H.tests, H.assertions, failed))
if #H.tests == 0 or failed > 0 then os.exit(1) end
