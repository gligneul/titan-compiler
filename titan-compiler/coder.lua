local ast = require "titan-compiler.ast"
local checker = require "titan-compiler.checker"
local util = require "titan-compiler.util"
local pretty = require "titan-compiler.pretty"
local types = require "titan-compiler.types"

local coder = {}

local generate_program
local generate_exp

function coder.generate(filename, input, modname)
    local prog, errors = checker.check(filename, input)
    if not prog then return false, errors end
    local code = generate_program(prog, modname)
    return code, errors
end

local whole_file_template = [[
/* This file was generated by the Titan compiler. Do not edit by hand */
/* Indentation and formatting courtesy of titan-compiler/pretty.lua */

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lapi.h"
#include "lfunc.h"
#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "ltable.h"

${DEFINE_FUNCTIONS}

int luaopen_${MODNAME}(lua_State *L)
{
    Table *titan_globals;
    lua_checkstack(L, 3); // TODO
    ${INITIALIZE_TOPLEVEL}
    ${CREATE_MODULE_TABLE}
    return 1;
}
]]

--
-- C syntax
--

-- Technically, we only need to escape the quote and backslash
-- But quoting some extra things helps readability...
local some_c_escape_sequences = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\a"] = "\\a",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\v"] = "\\v",
}

local function c_string(s)
    return '"' .. (s:gsub('.', some_c_escape_sequences)) .. '"'
end

local function c_integer(n)
    return string.format("%i", n)
end

local function c_boolean(b)
    if b then
        return c_integer(1)
    else
        return c_integer(0)
    end
end

local function c_float(n)
    return string.format("%f", n)
end

local function c_declaration(ctyp, varname)
    -- This simple concatenation won't work with function pointers
    return ctyp .. " " .. varname
end

--
--
--

-- This name-mangling scheme is designed to avoid clashes between the function
-- names created in separate models.
local function mangle_function_name(modname, funcname, suffix)
    return string.format("ttt_%d%s%d%s%s",
        #modname, modname, #funcname, funcname, suffix)
end

local function local_name(varname)
    return string.format("local_%s", varname)
end

-- @param type Type of the titan value
-- @returns type of the corresponding C variable
local function ctype(typ)
    local tag = typ._tag
    if     tag == types.T.Nil      then return "int"
    elseif tag == types.T.Boolean  then return "int"
    elseif tag == types.T.Integer  then return "lua_Integer"
    elseif tag == types.T.Float    then return "lua_Number"
    elseif tag == types.T.String   then return "TString *"
    elseif tag == types.T.Function then error("not implemented yet")
    elseif tag == types.T.Array    then return "Table *"
    elseif tag == types.T.Record   then error("not implemented yet")
    else error("impossible")
    end
end


local function get_slot(typ, src_slot_address)
    local tmpl
    local tag = typ._tag
    if     tag == types.T.Nil      then tmpl = "0"
    elseif tag == types.T.Boolean  then tmpl = "bvalue(${SRC})"
    elseif tag == types.T.Integer  then tmpl = "ivalue(${SRC})"
    elseif tag == types.T.Float    then tmpl = "fltvalue(${SRC})"
    elseif tag == types.T.String   then tmpl = "tsvalue(${SRC})"
    elseif tag == types.T.Function then error("not implemented")
    elseif tag == types.T.Array    then tmpl = "hvalue(${SRC})"
    elseif tag == types.T.Record   then error("not implemented")
    else error("impossible")
    end
    return util.render(tmpl, {SRC = src_slot_address})
end


local function set_slot(typ, dst_slot_address, value)
    local tmpl
    local tag = typ._tag
    if     tag == types.T.Nil      then tmpl = "setnilvalue(${DST});"
    elseif tag == types.T.Boolean  then tmpl = "setbvalue(${DST}, ${SRC});"
    elseif tag == types.T.Integer  then tmpl = "setivalue(${DST}, ${SRC});"
    elseif tag == types.T.Float    then tmpl = "setfltvalue(${DST}, ${SRC});"
    elseif tag == types.T.String   then tmpl = "setsvalue(L, ${DST}, ${SRC});"
    elseif tag == types.T.Function then error("not implemented yet")
    elseif tag == types.T.Array    then tmpl = "sethvalue(L, ${DST}, ${SRC});"
    elseif tag == types.T.Record   then error("not implemented yet")
    else error("impossible")
    end
    return util.render(tmpl, { DST = dst_slot_address, SRC = value })
end

local function toplevel_is_value_declaration(tl_node)
    local tag = tl_node._tag
    if     tag == ast.Toplevel.Func then
        return true
    elseif tag == ast.Toplevel.Var then
        return true
    elseif tag == ast.Toplevel.Record then
        return false
    elseif tag == ast.Toplevel.Import then
        return false
    else
        error("impossible")
    end
end

generate_program = function(prog, modname)

    -- Find where each global variable gets stored in the global table
    local n_toplevel = 0
    do
        for _, tl_node in ipairs(prog) do
            if toplevel_is_value_declaration(tl_node) then
                tl_node._global_index = n_toplevel
                n_toplevel = n_toplevel + 1
            end
        end
    end

    -- Create toplevel function declarations
    local define_functions
    do
        local function_definitions = {}
        for _, tl_node in ipairs(prog) do
            if tl_node._tag == ast.Toplevel.Func then
                -- Titan entry point
                local titan_entry_point_name =
                    mangle_function_name(modname, tl_node.name, "_titan")

                assert(#tl_node._type.rettypes == 1)
                local ret_ctype = ctype(tl_node._type.rettypes[1])

                local args = {}
                table.insert(args, [[lua_State * L]])
                for _, param in ipairs(tl_node.params) do
                    local name = param.name
                    local typ  = param._type
                    table.insert(args,
                        c_declaration(ctype(typ), local_name(name)))
                end

                table.insert(function_definitions,
                    util.render([[
                        ${RET} ${NAME}(${ARGS})
                        {
                            ${BODY}
                        }
                    ]], {
                        RET = ret_ctype,
                        NAME = titan_entry_point_name,
                        ARGS = table.concat(args, ", "),
                        BODY = generate_stat(tl_node.block)
                    })
                )

                -- Lua entry point
                local lua_entry_point_name =
                    mangle_function_name(modname, tl_node.name, "_lua")

                assert(#tl_node._type.rettypes == 1)
                local ret_typ = tl_node._type.rettypes[1]

                local args = {}
                table.insert(args, [[L]])
                for i, param in ipairs(tl_node.params) do
                    local slot = util.render([[L->ci->func + ${I}]], {
                        I = c_integer(i)
                    })
                    table.insert(args, get_slot(param._type, slot))
                end

                table.insert(function_definitions,
                    util.render([[
                        int ${LUA_ENTRY_POINT}(lua_State *L)
                        {
                            ${RET_DECL} = ${TITAN_ENTRY_POINT}(${ARGS});
                            ${SET_RET}
                            api_incr_top(L);
                            return 1;
                        }
                    ]], {
                        LUA_ENTRY_POINT = lua_entry_point_name,
                        TITAN_ENTRY_POINT = titan_entry_point_name,
                        RET_DECL = c_declaration(ctype(ret_typ), "ret"),
                        ARGS = table.concat(args, ", "),
                        SET_RET = set_slot(ret_typ, "L->top", "ret"),
                    })
                )

                --
                tl_node._titan_entry_point = titan_entry_point_name
                tl_node._lua_entry_point = lua_entry_point_name
            end
        end
        define_functions = table.concat(function_definitions, "\n")
    end

    -- Construct the values in the toplevel
    local initialize_toplevel
    do
        local parts = {}

        table.insert(parts,
            util.render([[
                {
                    /* Initialize titan_globals */
                    titan_globals = luaH_new(L);
                    luaH_resizearray(L, titan_globals, ${N_TOPLEVEL});
            ]], {
                N_TOPLEVEL = n_toplevel
            })
        )

        for _, tl_node in ipairs(prog) do
            if tl_node._global_index then
                local arr_slot = util.render([[ &titan_globals->array[${I}] ]], {
                    I = c_integer(tl_node._global_index)
                })

                local tag = tl_node._tag
                if     tag == ast.Toplevel.Func then
                    table.insert(parts,
                        util.render([[
                            {
                                CClosure *func = luaF_newCclosure(L, 1);
                                func->f = ${LUA_ENTRY_POINT};
                                sethvalue(L, &func->upvalue[0], titan_globals);
                                setclCvalue(L, ${ARR_SLOT}, func);
                            }
                        ]],{
                            LUA_ENTRY_POINT = tl_node._lua_entry_point,
                            TITAN_ENTRY_POINT = tl_node._titan_entry_point,
                            ARR_SLOT = arr_slot,
                        })
                    )

                elseif tag == ast.Toplevel.Var then
                    local exp = tl_node.value
                    local cstats, cvalue = generate_exp(exp)
                    table.insert(parts, cstats)
                    table.insert(parts, set_slot(exp._type, arr_slot, cvalue))
                else
                    error("impossible")
                end
            end
        end
        table.insert(parts, "}")
        initialize_toplevel = table.concat(parts, "\n")
    end

    local create_module_table
    do
        local parts = {}

        table.insert(parts, "{")
        table.insert(parts, "/*Initialize module table*/")

        table.insert(parts,
            util.render([[ lua_createtable(L, 0, ${N}); ]], {
                N = n_toplevel
            })
        )

        for _, tl_node in ipairs(prog) do
            if tl_node._global_index and not tl_node.islocal then
                table.insert(parts,
                    util.render([[
                        lua_pushstring(L, ${NAME});
                        setobj(L, L->top, &titan_globals->array[${I}]); api_incr_top(L);
                        lua_settable(L, -3);
                    ]], {
                        NAME = c_string(ast.toplevel_name(tl_node)),
                        I = c_integer(tl_node._global_index)
                    })
                )
            end
        end

        table.insert(parts, "}")
        create_module_table = table.concat(parts, "\n")
    end

    local code = util.render(whole_file_template, {
        MODNAME = modname,
        DEFINE_FUNCTIONS = define_functions,
        INITIALIZE_TOPLEVEL = initialize_toplevel,
        CREATE_MODULE_TABLE = create_module_table,
    })
    return pretty.reindent_c(code)
end


generate_stat = function(stat)
    local tag = stat._tag
    if     tag == ast.Stat.Block then
        local cstatss = {}
        for _, inner_stat in ipairs(stat.stats) do
            local cstats = generate_stat(inner_stat)
            table.insert(cstatss, cstats)
        end
        return table.concat(cstatss, "\n")

    elseif tag == ast.Stat.While then
        error("not implemented yet")

    elseif tag == ast.Stat.Repeat then
        error("not implemented yet")

    elseif tag == ast.Stat.If then
        error("not implemented yet")

    elseif tag == ast.Stat.For then
        error("not implemented yet")

    elseif tag == ast.Stat.Assign then
        error("not implemented yet")

    elseif tag == ast.Stat.Decl then
        error("not implemented yet")

    elseif tag == ast.Stat.Call then
        error("not implemented yet")

    elseif tag == ast.Stat.Return then
        local cstats, cvalue = generate_exp(stat.exp)
        return util.render([[
            ${CSTATS}
            return ${CVALUE};
        ]], {
            CSTATS = cstats,
            CVALUE = cvalue
        })

    else
        error("impossible")
    end
end

-- Returns (statements, value)
generate_exp = function(exp) -- TODO
    local tag = exp._tag
    if     tag == ast.Exp.Nil then
        return "", c_integer(0)

    elseif tag == ast.Exp.Bool then
        return "", c_boolean(exp.value)

    elseif tag == ast.Exp.Integer then
        return "", c_integer(exp.value)

    elseif tag == ast.Exp.Float then
        return "", c_float(exp.value)

    elseif tag == ast.Exp.String then
        error("not implemented yet")

    elseif tag == ast.Exp.Initlist then
        error("not implemented yet")

    elseif tag == ast.Exp.Unop then
        error("not implemented yet")

    elseif tag == ast.Exp.Concat then
        error("not implemented yet")

    elseif tag == ast.Exp.Binop then
        error("not implemented yet")

    elseif tag == ast.Exp.Cast then
        error("not implemented yet")

    else
        error("impossible")
    end
end

return coder
