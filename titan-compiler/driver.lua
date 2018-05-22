local parser = require  "titan-compiler.parser"
local util = require "titan-compiler.util"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local pretty = require "titan-compiler.pretty"
local types = require "titan-compiler.types"

local lfs = require "lfs"

local driver = {}

driver.imported = {}

driver.TITAN_BIN_PATH = os.getenv("TITAN_PATH_0_5") or os.getenv("TITAN_PATH") or ".;/usr/local/lib/titan/0.5"
driver.TITAN_SOURCE_PATH = "."
driver.LUA_SOURCE_PATH = "lua-5.3.4/src/"
driver.TITAN_RUNTIME_PATH = "titan-runtime/"
driver.CFLAGS = "--std=c99 -O2 -Wall -fPIC"
driver.CC = "cc"

local LUA_OFILES = {
    "lgc.o", "ltable.o", "lstring.o", "lfunc.o", "lvm.o", "lobject.o",
    "ldebug.o", "ltm.o", "lmem.o", "ldo.o", "lstate.o", "lctype.o",
    "lopcodes.o", "lparser.o", "llex.o", "lundump.o", "lzio.o", "lcode.o"
}

local CIRCULAR_MARK = {}

local function shell(cmd)
    local p = io.popen(cmd)
    out = p:read("*a")
    p:close()
    return out
end

driver.UNAME = shell("uname")

local function findmodule(paths, modname, extension)
    local modf = modname:gsub("[.]", "/") .. extension
    for path in paths:gmatch("[^;]+") do
        local filename = path .. "/" .. modf
        local mtime = lfs.attributes(filename, "modification")
        if mtime then return mtime, filename end
    end
    return nil
end

function driver.defaultloader(modname)
    if driver.imported[modname] == CIRCULAR_MARK then
        driver.imported[modname] = nil
        return false, "circular reference to module"
    end
    if driver.imported[modname] then
        local mod = driver.imported[modname]
        return true, mod.type, {}
    end
    local mtime_bin, binf = findmodule(driver.TITAN_BIN_PATH, modname, ".so")
    local mtime_src, srcf = findmodule(driver.TITAN_SOURCE_PATH, modname, ".titan")
    if mtime_bin and (not mtime_src or mtime_bin >= mtime_src) then
        local typesf, err = package.loadlib(binf, modname:gsub("[%-.]", "_") .. "_types")
        if not typesf then return false, err end
        local ok, types_or_err = pcall(typesf)
        if not ok then return false, types_or_err end
        local modtf, err = load("return " .. types_or_err, modname, "t", types)
        if not modtf then return false, err end
        local ok, modt_or_err = pcall(modtf)
        if not ok then return false, modt_or_err end
        driver.imported[modname] = { type = modt_or_err, compiled = true }
        return true, modt_or_err, {}
    end
    if not mtime_src then return false, "module '" .. modname .. "' not found" end
    local input, err = util.get_file_contents(srcf)
    if not input then return false, err end
    local ast, err = parser.parse(srcf, input)
    if not ast then return false, parser.error_to_string(err, srcf) end
    driver.imported[modname] = CIRCULAR_MARK
    local modt, errors = checker.check(modname, ast, input, srcf, driver.defaultloader)
    driver.imported[modname] = { ast = ast, type = modt, filename = srcf }
    return true, modt, errors
end

function driver.tableloader(modtable, imported)
    local function loader(modname)
        if imported[modname] == CIRCULAR_MARK then
            imported[modname] = nil
            return false, "circular reference to module"
        end
        if imported[modname] then
            local mod = imported[modname]
            return true, mod.type, {}
        end
        local modf = "./" .. modname .. ".titan"
        local input = modtable[modname]
        local ast, err = parser.parse(modf, modtable[modname])
        if not ast then return false, parser.error_to_string(err, modf) end
        imported[modname] = CIRCULAR_MARK
        local modt, errors = checker.check(modname, ast, input, modf, loader)
        local mods = types.serialize(modt)
        local modtf, err = load("return " .. mods, modname, "t", types)
        if not modtf then return false, err end
        local ok, modt_or_err = pcall(modtf)
        if not ok then return false, modt_or_err end
        modt = modt_or_err
        imported[modname] = { ast = ast, type = modt, filename = modf }
        return true, modt, errors
    end
    return loader
end

local function shared_flag()
    local shared = "-shared"
    if string.match(driver.UNAME, "Darwin") then
        shared = shared .. " -undefined dynamic_lookup"
    end
    return shared
end

local function static_flag()
    return "-c"
end

function driver.compile_module(modname, mod, link, is_static, verbose)
    if mod.compiled then return true, mod.compiled end
    local ok, err, libname = driver.compile(modname, mod.ast, mod.filename, link, is_static, verbose)
    if not ok then return nil, err end
    mod.compiled = libname
    return true, nil, libname
end

local function check_runtime()
    local runtime_c = driver.TITAN_RUNTIME_PATH .. "titan.c"
    local runtime_o = driver.TITAN_RUNTIME_PATH .. "titan.o"
    if not lfs.attributes(runtime_o, "size") then
        local args = {driver.CC, driver.CFLAGS, "-c", runtime_c,
            "-I", driver.TITAN_RUNTIME_PATH, "-I", driver.LUA_SOURCE_PATH,
            "-o", runtime_o }
        os.execute(table.concat(args, " "))
    end
end

function driver.compile(modname, ast, sourcef, link, is_static, verbose)
    check_runtime()
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    local code = coder.generate(modname, ast, not is_static)
    code = pretty.reindent_c(code)
    local filename = sourcef:gsub("[.]titan$", "") .. ".c"

    local libname = sourcef:gsub("[.]titan$", "") .. (is_static and ".o" or ".so")
    os.remove(filename)
    os.remove(libname)
    local ok, err = util.set_file_contents(filename, code)
    if not ok then return nil, err end
    local libflag = is_static and static_flag() or shared_flag()
    local ofiles = ""
    if not is_static then
        ofiles = driver.LUA_SOURCE_PATH ..
            table.concat(LUA_OFILES, " " .. driver.LUA_SOURCE_PATH)
    end
    local runtime = not is_static and driver.TITAN_RUNTIME_PATH .. "titan.o" or ""
    local args = {driver.CC, driver.CFLAGS, libflag, filename, ofiles,
                  runtime, "-I", "titan-runtime",
                  "-I", driver.LUA_SOURCE_PATH, "-o", libname}
    if link and not is_static then
        local libs = util.split_string(link, ",")
        for _, lib in ipairs(libs) do
            table.insert(args, "-l" .. lib)
        end
    end
    local cmd = table.concat(args, " ")
    if verbose then
        print(cmd)
    end
    ok, err = os.execute(cmd)
    if ok then
        return ok, nil, libname
    else
        return nil, err
    end
end

local entrypoint_template = [[

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

/* portable alerts, from srlua */
#ifdef _WIN32
#include <windows.h>
#define alert(message)  MessageBox(NULL, message, progname, MB_ICONERROR | MB_OK)
#define getprogname()   char name[MAX_PATH]; argv[0]= GetModuleFileName(NULL,name,sizeof(name)) ? name : NULL;
#else
#define alert(message)  fprintf(stderr,"%s: %s\n", "$PROGNAME", message)
#define getprogname()
#endif

/* fatal error, from srlua */
static void fatal(const char* message) {
    alert(message);
    exit(EXIT_FAILURE);
}

/* main script launcher, based on srlua */
static int pmain(lua_State *L) {
    int argc = lua_tointeger(L, 1);
    char** argv = lua_touserdata(L, 2);
    int i;
    const char code[] = "local arg = ...;\nreturn\nrequire('$MODNAME').main(arg);";
    luaL_loadstring(L, code);
    if (lua_type(L, lua_gettop(L)) == LUA_TSTRING) {
        fatal(lua_tostring(L, -1));
    }
    lua_createtable(L, argc, 0);
    for (i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_call(L, 1, 1);
    return 1;
}

/* error handler, from luac */
static int msghandler (lua_State *L) {
    /* is error object not a string? */
    const char *msg = lua_tostring(L, 1);
    if (msg == NULL) {
        /* does it have a metamethod that produces a string */
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) {
            /* then that is the message */
            return 1;
        } else {
            msg = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
        }
    }
    /* append a standard traceback */
    luaL_traceback(L, L, msg, 1);
    return 1;
}

$OPENFN_SIGS

/* main function, based on srlua */
int main(int argc, char** argv) {
    int ret;
    lua_State* L;
    getprogname();
    if (argv[0] == NULL) {
        fatal("cannot locate this executable");
    }
    L = luaL_newstate();
    if (L == NULL) {
        fatal("not enough memory for state");
    }
    luaL_openlibs(L);
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    $OPENFNS
    lua_pushcfunction(L, msghandler);
    lua_pushcfunction(L, pmain);
    lua_pushinteger(L, argc);
    lua_pushlightuserdata(L, argv);
    if (lua_pcall(L, 2, 1, -4) != 0) {
        fatal(lua_tostring(L, -1));
    }
    ret = lua_tointeger(L, -1);
    lua_close(L);
    return ret;
}

]]

local function write_entrypoint(modname, modules)
    local entrypoint_c = modname:gsub("[.]", "/") .. "__entrypoint.c"
    local fd, err = io.open(entrypoint_c, "w")
    if not fd then return nil, err end
    local openfns, openfn_sigs = {}, {}
    for _, mod in ipairs(modules) do
        table.insert(openfns, util.render([[
            lua_pushcfunction(L, $LUAOPEN_FN);
            lua_setfield(L, -2, "$MODNAME");
        ]], {
            LUAOPEN_FN = "luaopen_" .. mod:gsub("[.]", "_"),
            MODNAME = mod,
        }))
        table.insert(openfn_sigs, util.render([[
            int $LUAOPEN_FN(lua_State* L);
        ]], { LUAOPEN_FN = "luaopen_" .. mod:gsub("[.]", "_") }))
    end
    local ok, err = fd:write(util.render(entrypoint_template, {
        PROGNAME = modname:gsub(".*[.]", ""),
        OPENFNS = table.concat(openfns, "\n"),
        OPENFN_SIGS = table.concat(openfn_sigs, "\n"),
        MODNAME = modname,
    }))
    if err then return nil, err end
    fd:close()
    return entrypoint_c
end

function driver.compile_program(modname, modules, link, verbose)
    local execname = modname:gsub("[.]", "/")
    os.remove(execname)

    local entrypoint_c, err = write_entrypoint(modname, modules)
    if err then return nil, err end

    local args = {driver.CC, driver.CFLAGS, "-o", execname,
                "-I", driver.TITAN_RUNTIME_PATH, "-I", driver.LUA_SOURCE_PATH,
                entrypoint_c}
    for _, mod in ipairs(modules) do
        table.insert(args, mod:gsub("[.]", "/") .. ".o")
    end

    table.insert(args, driver.TITAN_RUNTIME_PATH .. "titan.o")

    table.insert(args, driver.LUA_SOURCE_PATH .. "/liblua.a")
    table.insert(args, "-ldl")
    table.insert(args, "-lm")
    if link then
        local libs = util.split_string(link, ",")
        for _, lib in ipairs(libs) do
            table.insert(args, "-l" .. lib)
        end
    end
    local cmd = table.concat(args, " ")
    if verbose then
        print(cmd)
    end
    return os.execute(cmd)
end

return driver
