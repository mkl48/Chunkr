-- Parse/compile check for every source file (no execution). Catches syntax
-- slips - notably ambiguous `(`-statements - before Studio does.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failed = 0
local checked = 0

local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			walk(path)
		elseif name:match("%.luau$") then
			checked += 1
			local ok, err = pcall(luau.compile, fs.readFile(path))
			if not ok then
				failed += 1
				print(`FAIL {path}\n  {err}`)
			end
		end
	end
end

walk("src")
walk("examples")

if failed > 0 then
	print(`parse-check: {failed}/{checked} files failed`)
	process.exit(1)
end
print(`parse-check OK - {checked} files compile`)
