# Titan
[![Build Status](https://travis-ci.org/titan-lang/titan-v0.svg?branch=master)](https://travis-ci.org/titan-lang/titan-v0)
[![Coverage Status](https://codecov.io/gh/titan-lang/titan-v0/coverage.svg?branch=master)](https://codecov.io/gh/titan-lang/titan-v0/branch/master)

Titan is a new programming language, designed to be a statically-typed,
ahead-of-time compiled sister language to [Lua](http://www.lua.org). It is an
application programming language with a focus on performance.

This repository contains the work-in-progress for the initial prototype
of the Titan compiler. It is under active development and it targets compiling Titan modules
to C code in the [artisanal style](https://github.com/titan-lang/artisanal-titan).
For more information, please see the [reference manual](https://github.com/titan-lang/titan-lang-docs/blob/master/manual.md).

# Requirements for running the compiler

1. [Lua](http://www.lua.org/) >= 5.3.0
2. [LPegLabel](https://github.com/sqmedeiros/lpeglabel) >= 1.0.0
3. [inspect](https://github.com/kikito/inspect.lua) >= 3.1.0
4. [argparse](https://github.com/mpeterv/argparse) >= 0.5.0

# Install

Titan must be installed in a standard location;
[LuaRocks](http://luarocks.org) will do this, and will also install all dependencies automatically.

        $ [install luarocks]
        $ luarocks install titan-lang-scm-1.rockspec

# Usage

        $ titanc [options] <input>

# Compiler options

        --print-ast                     Print the AST.
        --print-types                   Print the AST with types.
        -o <output>, --output <output>  Output file.
        -h, --help                      Show this help message and exit.
