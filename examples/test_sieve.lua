local N    = arg[1] and tonumber(arg[1]) or 1000000

local f = require("examples.artisanal").sieve

local ps = f(N)
print(#ps)
