local checker = {}

local symtab = require "titan-compiler.symtab"
local types = require "titan-compiler.types"
local ast = require "titan-compiler.ast"
local util = require "titan-compiler.util"

local checkstat
local checkexp

local function typeerror(errors, msg, pos, ...)
    local l, c = util.get_line_number(errors.subject, pos)
    msg = string.format("%s:%d:%d: type error: %s", errors.filename, l, c, string.format(msg, ...))
    table.insert(errors, msg)
end

checker.typeerror = typeerror

-- Checks if two types are the same, and logs an error message otherwise
--   term: string describing what is being compared
--   expected: type that is expected
--   found: type that was actually present
--   errors: list of compile-time errors
--   pos: position of the term that is being compared
local function checkmatch(term, expected, found, errors, pos)
    if types.coerceable(found, expected) or not types.compatible(expected, found) then
        local msg = "types in %s do not match, expected %s but found %s"
        msg = string.format(msg, term, types.tostring(expected), types.tostring(found))
        typeerror(errors, msg, pos)
    end
end

-- Converts an AST type declaration into a typechecker type
--   typenode: AST node
--   errors: list of compile-time errors
--   returns a type (from types.lua)
local function typefromnode(typenode, errors)
    local tag = typenode._tag
    if tag == "Type_Array" then
        return types.Array(typefromnode(typenode.subtype, errors))
    elseif tag == "Type_Name" then
        local t = types.Base(typenode.name)
        if not t then
            typeerror(errors, "type name " .. typenode.name .. " is invalid", typenode._pos)
            t = types.Integer
        end
        return t
    elseif tag == "Type_Function" then
        if #typenode.argtypes ~= 1 then
            error("functions with 0 or 2+ return values are not yet implemented")
        end

        local ptypes = {}
        for _, ptype in ipairs(typenode.argtypes) do
            table.insert(ptypes, typefromnode(ptype, errors))
        end
        local rettypes = {}
        for _, rettype in ipairs(typenode.rettypes) do
            table.insert(rettypes, typefromnode(rettype, errors))
        end

        return types.Function(ptypes, rettypes)
    else
        error("invalid node tag " .. tag)
    end
end

-- tries to coerce node to target type
--    node: expression node
--    target: target type
--    returns node wrapped in a coercion, or original node
local function trycoerce(node, target, errors)
    if types.coerceable(node._type, target) then
        local n = ast.Exp_Cast(node._pos, node, target)
        local l, _ = util.get_line_number(errors.subject, n._pos)
        n._lin = l
        n._type = target
        return n
    else
        return node
    end
end

local function trytostr(node)
    local source = node._type
    if types.equals(source, types.Integer) or
      types.equals(source, types.Float) then
        local n = ast.Exp_Cast(node._pos, node, types.String)
        n._type = types.String
        return n
    else
        return node
    end
end

-- First typecheck pass over the module, typecheks module variables
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
--   annotates the top-level nodes with their types in a "_type" field
--   annotates whether a top-level declaration is duplicated with a "_ignore" field
local function firstpass(ast, st, errors)
    for _, tlnode in ipairs(ast) do
        local name
        if tlnode._tag == "TopLevel_Var" then
            name = tlnode.decl.name
            if tlnode.decl.type then
                tlnode._type = typefromnode(tlnode.decl.type, errors)
                checkexp(tlnode.value, st, errors, tlnode._type)
            else
                checkexp(tlnode.value, st, errors)
                tlnode._type = tlnode.value._type
            end
            tlnode._lin = util.get_line_number(errors.subject, tlnode._pos)
            if st:find_dup(name) then
                typeerror(errors, "duplicate variable declaration for " .. name, tlnode._pos)
                tlnode._ignore = true
            else
                tlnode.value = trycoerce(tlnode.value, tlnode._type, errors)
                checkmatch("declaration of module variable " .. name,
                    tlnode._type, tlnode.value._type, errors, tlnode._pos)
                st:add_symbol(name, tlnode)
            end
        end
    end
end


-- Second typecheck pass over the module, collects type information
-- for top-level functions
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
--   annotates the top-level nodes with their types in a "_type" field
--   annotates whether a top-level declaration is duplicated with a "_ignore" field
local function secondpass(ast, st, errors)
    for _, tlnode in ipairs(ast) do
        local name
        if tlnode._tag == "TopLevel_Func" then
            if #tlnode.rettypes ~= 1 then
                error("functions with 0 or 2+ return values are not yet implemented")
            end

            name = tlnode.name
            local ptypes = {}
            for _, pdecl in ipairs(tlnode.params) do
                table.insert(ptypes, typefromnode(pdecl.type, errors))
            end
            local rettypes = {}
            for _, rt in ipairs(tlnode.rettypes) do
                table.insert(rettypes, typefromnode(rt, errors))
            end
            tlnode._type = types.Function(ptypes, rettypes)
            if st:find_dup(name) then
                typeerror(errors, "duplicate function or variable declaration for " .. name, tlnode._pos)
                tlnode._ignore = true
            else
                st:add_symbol(name, tlnode)
            end
        end
    end
end

-- Typechecks a repeat/until statement
--   node: Stat_Repeat AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for repeat/until)
local function checkrepeat(node, st, errors)
    for _, stat in ipairs(node.block.stats) do
        checkstat(stat, st, errors)
    end
    checkexp(node.condition, st, errors, types.Boolean)
    return false
end

-- Typechecks a for loop statement
--   node: Stat_For AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for 'for' loop)
local function checkfor(node, st, errors)
    local ftype
    if node.decl.type then
      checkstat(node.decl, st, errors)
      ftype = node.decl._type
      if not types.equals(ftype, types.Integer) and
        not types.equals(ftype, types.Float) then
        typeerror(errors, "type of for control variable " .. node.decl.name .. " must be integer or float", node.decl._pos)
        node.decl._type = types.Integer
        ftype = types.Integer
      end
      checkexp(node.start, st, errors, ftype)
      node.start = trycoerce(node.start, ftype, errors)
    else
      checkexp(node.start, st, errors)
      ftype = node.start._type
      node.decl._type = ftype
      checkstat(node.decl, st, errors)
      if not types.equals(ftype, types.Integer) and
        not types.equals(ftype, types.Float) then
        typeerror(errors, "type of for control variable " .. node.decl.name .. " must be integer or float", node.decl._pos)
        node.decl._type = types.Integer
        ftype = types.Integer
      end
    end
    checkmatch("'for' start expression", ftype, node.start._type, errors, node.start._pos)
    checkexp(node.finish, st, errors, ftype)
    node.finish = trycoerce(node.finish, ftype, errors)
    checkmatch("'for' finish expression", ftype, node.finish._type, errors, node.finish._pos)
    if node.inc then
        checkexp(node.inc, st, errors, ftype)
        node.inc = trycoerce(node.inc, ftype, errors)
        checkmatch("'for' step expression", ftype, node.inc._type, errors, node.inc._pos)
    end
    checkstat(node.block, st, errors)
    return false
end

-- Typechecks a block statement
--   node: Stat_Block AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether the block always returns from the containing function
local function checkblock(node, st, errors)
    local ret = false
    for _, stat in ipairs(node.stats) do
        ret = ret or checkstat(stat, st, errors)
    end
    return ret
end

-- Typechecks a statement or declaration
--   node: A Decl_Decl or Stat_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for repeat/until)
function checkstat(node, st, errors)
    local tag = node._tag
    if tag == "Decl_Decl" then
        st:add_symbol(node.name, node)
        node._type = node._type or typefromnode(node.type, errors)
    elseif tag == "Stat_Decl" then
        for i = 1, #node.decl do
            local decl_i = node.decl[i]
            local exp_i = node.exp[i]
            if exp_i then
                if decl_i.type then
                    checkstat(decl_i, st, errors)
                    checkexp(exp_i, st, errors, decl_i._type)
                else
                    checkexp(exp_i, st, errors)
                    decl_i._type = exp_i._type
                    checkstat(decl_i, st, errors)
                end
                exp_i = trycoerce(exp_i, decl_i._type, errors)
                node.exp[i] = exp_i
                checkmatch("declaration of local variable " .. decl_i.name,
                    decl_i._type, exp_i._type, errors, decl_i._pos)
            else
                local msg = "expression list is shorter than variable list"
                typeerror(errors, msg, node._pos)
                break
            end
        end
        if #node.exp > #node.decl then
            local msg = "expression list is longer than variable list"
            typeerror(errors, msg, node._pos)
        end
    elseif tag == "Stat_Block" then
        return st:with_block(checkblock, node, st, errors)
    elseif tag == "Stat_While" then
        checkexp(node.condition, st, errors, types.Boolean)
        st:with_block(checkstat, node.block, st, errors)
    elseif tag == "Stat_Repeat" then
        st:with_block(checkrepeat, node, st, errors)
    elseif tag == "Stat_For" then
        st:with_block(checkfor, node, st, errors)
    elseif tag == "Stat_Assign" then
        checkexp(node.var, st, errors)
        checkexp(node.exp, st, errors, node.var._type)
        local texp = node.var._type
        if types.has_tag(texp, "Module") then
            typeerror(errors, "trying to assign to a module", node._pos)
        elseif types.has_tag(texp, "Function") then
            typeerror(errors, "trying to assign to a function", node._pos)
        else
            -- mark this declared variable as assigned to
            if node.var._tag == "Var_Name" and node.var._decl then
                node.var._decl._assigned = true
            end
            node.exp = trycoerce(node.exp, node.var._type, errors)
            if node.var._tag ~= "Var_Bracket" or not types.equals(node.exp._type, types.Nil) then
                checkmatch("assignment", node.var._type, node.exp._type, errors, node.var._pos)
            end
        end
    elseif tag == "Stat_Call" then
        checkexp(node.callexp, st, errors)
    elseif tag == "Stat_Return" then
        local ftype = st:find_symbol("$function")._type
        assert(#ftype.rettypes == 1)
        local tret = ftype.rettypes[1]
        checkexp(node.exp, st, errors, tret)
        node.exp = trycoerce(node.exp, tret, errors)
        node._type = tret
        checkmatch("return", tret, node.exp._type, errors, node.exp._pos)
        node._type = tret
        return true
    elseif tag == "Stat_If" then
        local ret = true
        for _, thn in ipairs(node.thens) do
            checkexp(thn.condition, st, errors, types.Boolean)
            ret = checkstat(thn.block, st, errors) and ret
        end
        if node.elsestat then
            ret = checkstat(node.elsestat, st, errors) and ret
        else
            ret = false
        end
        return ret
    else
        error("invalid node tag " .. tag)
    end
    return false
end

-- Typechecks an expression
--   node: Var_* or Exp_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   annotates the node with its type in a "_type" field
function checkexp(node, st, errors, context)
    -- TODO coercions integer <-> float
    local tag = node._tag
    if tag == "Var_Name" then
        local decl = st:find_symbol(node.name)
        if not decl then
            local msg = "variable '" .. node.name .. "' not declared"
            typeerror(errors, msg, node._pos)
            node._type = types.Integer
        else
            decl._used = true
            node._decl = decl
            node._type = decl._type
        end
    elseif tag == "Var_Dot" then
        assert(node.exp.var, "left side of dot expression is not var")
        checkexp(node.exp.var, st, errors)
        node.exp._type = node.exp.var._type
        local texp = node.exp._type
        if types.has_tag(texp, "Module") then
            local mod = texp
            if not mod.members[node.name] then
                local msg = "module variable '" .. node.name .. "' not found inside module '" .. mod.name .. "'"
                typeerror(errors, msg, node._pos)
                node._type = types.Integer
            else
                local decl = mod.members[node.name]
                node._decl = decl
                node._type = decl
            end
        elseif types.has_tag(texp, "Record") then
            error("not implemented yet")
        else
            typeerror(errors, "trying to access member '" .. node.name ..
            "' of value that is not a record or module but " .. types.tostring(texp), node._pos)
            node._type = types.Integer
        end
    elseif tag == "Var_Bracket" then
        local l, _ = util.get_line_number(errors.subject, node._pos)
        node._lin = l
        checkexp(node.exp1, st, errors, context and types.Array(context))
        if not types.has_tag(node.exp1._type, "Array") then
            typeerror(errors, "array expression in indexing is not an array but "
                .. types.tostring(node.exp1._type), node.exp1._pos)
            node._type = types.Integer
        else
            node._type = node.exp1._type.elem
        end
        checkexp(node.exp2, st, errors, types.Integer)
        -- always try to coerce index to integer
        node.exp2 = trycoerce(node.exp2, types.Integer, errors)
        checkmatch("array indexing", types.Integer, node.exp2._type, errors, node.exp2._pos)
    elseif tag == "Exp_Nil" then
        node._type = types.Nil
    elseif tag == "Exp_Bool" then
        node._type = types.Boolean
    elseif tag == "Exp_Integer" then
        node._type = types.Integer
    elseif tag == "Exp_Float" then
        node._type = types.Float
    elseif tag == "Exp_String" then
        node._type = types.String
    elseif tag == "Exp_InitList" then
        local econtext = context and context.elem
        local etypes = {}
        local isarray = true
        for _, field in ipairs(node.fields) do
            local exp = field.exp
            checkexp(exp, st, errors, econtext)
            table.insert(etypes, exp._type)
            isarray = isarray and not field.name
        end
        if isarray then
            local etype = econtext or etypes[1] or types.Integer
            node._type = types.Array(etype)
            for i, field in ipairs(node.fields) do
                field.exp = trycoerce(field.exp, etype, errors)
                local exp = field.exp
                checkmatch("array initializer at position " .. i, etype,
                           exp._type, errors, exp._pos)
            end
        else
            node._type = types.InitList(etypes)
        end
    elseif tag == "Exp_Var" then
        checkexp(node.var, st, errors, context)
        local texp = node.var._type
        if types.has_tag(texp, "Module") then
            typeerror(errors, "trying to access module '%s' as a first-class value", node._pos, node.var.name)
            node._type = types.Integer
        elseif types.has_tag(texp, "Function") then
            typeerror(errors, "trying to access a function as a first-class value", node._pos)
            node._type = types.Integer
        else
            node._type = texp
        end
    elseif tag == "Exp_Unop" then
        local op = node.op
        checkexp(node.exp, st, errors)
        local texp = node.exp._type
        local pos = node._pos
        if op == "#" then
            if not types.has_tag(texp, "Array") and not types.equals(texp, types.String) then
                typeerror(errors, "trying to take the length of a " .. types.tostring(texp) .. " instead of an array or string", pos)
            end
            node._type = types.Integer
        elseif op == "-" then
            if not types.equals(texp, types.Integer) and not types.equals(texp, types.Float) then
                typeerror(errors, "trying to negate a " .. types.tostring(texp) .. " instead of a number", pos)
            end
            node._type = texp
        elseif op == "~" then
            -- always tries to coerce floats to integer
            node.exp = types.equals(node.exp._type, types.Float) and trycoerce(node.exp, types.Integer, errors) or node.exp
            texp = node.exp._type
            if not types.equals(texp, types.Integer) then
                typeerror(errors, "trying to bitwise negate a " .. types.tostring(texp) .. " instead of an integer", pos)
            end
            node._type = types.Integer
        elseif op == "not" then
            -- always coerces other values to a boolean
            node.exp = trycoerce(node.exp, types.Boolean, errors)
            node._type = types.Boolean
        else
            error("invalid unary operation " .. op)
        end
    elseif tag == "Exp_Concat" then
        for i, exp in ipairs(node.exps) do
            checkexp(exp, st, errors, types.String)
            -- always tries to coerce numbers to string
            exp = trytostr(exp)
            node.exps[i] = exp
            local texp = exp._type
            if types.equals(texp, types.Value) then
                typeerror(errors, "cannot concatenate with value of type 'value'", exp._pos)
            elseif not types.equals(texp, types.String) then
                typeerror(errors, "cannot concatenate with " .. types.tostring(texp) .. " value", exp._pos)
            end
        end
        node._type = types.String
    elseif tag == "Exp_Binop" then
        local op = node.op
        checkexp(node.lhs, st, errors)
        local tlhs = node.lhs._type
        checkexp(node.rhs, st, errors)
        local trhs = node.rhs._type
        local pos = node._pos
        if op == "==" or op == "~=" then
            -- tries to coerce to value if either side is value
            if types.equals(tlhs, types.Value) or types.equals(trhs, types.Value) then
                node.lhs = trycoerce(node.lhs, types.Value, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value, errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if either side is float
            if types.equals(tlhs, types.Float) or types.equals(trhs, types.Float) then
                node.lhs = trycoerce(node.lhs, types.Float, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float, errors)
                trhs = node.rhs._type
            end
            if not types.compatible(tlhs, trhs) then
                typeerror(errors, "trying to compare values of different types: " ..
                    types.tostring(tlhs) .. " and " .. types.tostring(trhs), pos)
            end
            node._type = types.Boolean
        elseif op == "<" or op == ">" or op == "<=" or op == ">=" then
            -- tries to coerce to value if either side is value
            if types.equals(tlhs, types.Value) or types.equals(trhs, types.Value) then
                node.lhs = trycoerce(node.lhs, types.Value, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value, errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if either side is float
            if types.equals(tlhs, types.Float) or types.equals(trhs, types.Float) then
                node.lhs = trycoerce(node.lhs, types.Float, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float, errors)
                trhs = node.rhs._type
            end
            if not types.equals(tlhs, trhs) then
                if not types.equals(tlhs, types.Integer) and not types.equals(tlhs, types.Float) and types.equals(trhs, types.Integer) or types.equals(trhs, types.Float) then
                    typeerror(errors, "left hand side of relational expression is a " .. types.tostring(tlhs) .. " instead of a number", pos)
                elseif not types.equals(trhs, types.Integer) and not types.equals(trhs, types.Float) and types.equals(tlhs, types.Integer) or types.equals(tlhs, types.Float) then
                    typeerror(errors, "right hand side of relational expression is a " .. types.tostring(trhs) .. " instead of a number", pos)
                elseif not types.equals(tlhs, types.String) and types.equals(trhs, types.String) then
                    typeerror(errors, "left hand side of relational expression is a " .. types.tostring(tlhs) .. " instead of a string", pos)
                elseif not types.equals(trhs, types.String) and types.equals(tlhs, types.String) then
                    typeerror(errors, "right hand side of relational expression is a " .. types.tostring(trhs) .. " instead of a string", pos)
                else
                    typeerror(errors, "trying to use relational expression with " .. types.tostring(tlhs) .. " and " .. types.tostring(trhs), pos)
                end
            else
                if not types.equals(tlhs, types.Integer) and not types.equals(tlhs, types.Float) and not types.equals(tlhs, types.String) then
                    typeerror(errors, "trying to use relational expression with two " .. types.tostring(tlhs) .. " values", pos)
                end
            end
            node._type = types.Boolean
        elseif op == "+" or op == "-" or op == "*" or op == "%" or op == "//" then
            if not (types.equals(tlhs, types.Integer) or types.equals(tlhs, types.Float)) then
                typeerror(errors, "left hand side of arithmetic expression is a " .. types.tostring(tlhs) .. " instead of a number", pos)
            end
            if not (types.equals(trhs, types.Integer) or types.equals(trhs, types.Float)) then
                typeerror(errors, "right hand side of arithmetic expression is a " .. types.tostring(trhs) .. " instead of a number", pos)
            end
            -- tries to coerce to value if either side is value
            if types.equals(tlhs, types.Value) or types.equals(trhs, types.Value) then
                node.lhs = trycoerce(node.lhs, types.Value, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value, errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if either side is float
            if types.equals(tlhs, types.Float) or types.equals(trhs, types.Float) then
                node.lhs = trycoerce(node.lhs, types.Float, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float, errors)
                trhs = node.rhs._type
            end
            if types.equals(tlhs, types.Float) and types.equals(trhs, types.Float) then
                node._type = types.Float
            elseif types.equals(tlhs, types.Integer) and types.equals(trhs, types.Integer) then
                node._type = types.Integer
            else
                -- error
                node._type = types.Integer
            end
        elseif op == "/" or op == "^" then
            if types.equals(tlhs, types.Integer) then
                -- always tries to coerce to float
                node.lhs = trycoerce(node.lhs, types.Float, errors)
                tlhs = node.lhs._type
            end
            if types.equals(trhs, types.Integer) then
                -- always tries to coerce to float
                node.rhs = trycoerce(node.rhs, types.Float, errors)
                trhs = node.rhs._type
            end
            if not types.equals(tlhs, types.Float) then
                typeerror(errors, "left hand side of arithmetic expression is a " .. types.tostring(tlhs) .. " instead of a number", pos)
            end
            if not types.equals(trhs, types.Float) then
                typeerror(errors, "right hand side of arithmetic expression is a " .. types.tostring(trhs) .. " instead of a number", pos)
            end
            node._type = types.Float
        elseif op == "and" or op == "or" then
            -- tries to coerce to boolean if other side is boolean
            if types.equals(tlhs, types.Boolean) or types.equals(trhs, types.Boolean) then
                node.lhs = trycoerce(node.lhs, types.Boolean, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Boolean, errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to value if other side is value
            if types.equals(tlhs, types.Value) or types.equals(trhs, types.Value) then
                node.lhs = trycoerce(node.lhs, types.Value, errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value, errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if other side is float
            if types.equals(tlhs, types.Float) or types.equals(trhs, types.Float) then
              node.lhs = trycoerce(node.lhs, types.Float, errors)
              tlhs = node.lhs._type
              node.rhs = trycoerce(node.rhs, types.Float, errors)
              trhs = node.rhs._type
            end
            if not types.compatible(tlhs, trhs) then
              typeerror(errors, "left hand side of logical expression is a " ..
               types.tostring(tlhs) .. " but right hand side is a " ..
               types.tostring(trhs), pos)
            end
            node._type = tlhs
        elseif op == "|" or op == "&" or op == "<<" or op == ">>" then
            -- always tries to coerce floats to integer
            node.lhs = types.equals(node.lhs._type, types.Float) and trycoerce(node.lhs, types.Integer, errors) or node.lhs
            tlhs = node.lhs._type
            -- always tries to coerce floats to integer
            node.rhs = types.equals(node.rhs._type, types.Float) and trycoerce(node.rhs, types.Integer, errors) or node.rhs
            trhs = node.rhs._type
            if not types.equals(tlhs, types.Integer) then
                typeerror(errors, "left hand side of arithmetic expression is a " .. types.tostring(tlhs) .. " instead of a number", pos)
            end
            if not types.equals(trhs, types.Integer) then
                typeerror(errors, "right hand side of arithmetic expression is a " .. types.tostring(trhs) .. " instead of a number", pos)
            end
            node._type = types.Integer
        else
            error("invalid binary operation " .. op)
        end
    elseif tag == "Exp_Call" then
        assert(node.exp._tag == "Exp_Var", "function calls are first-order only!")
        local var = node.exp.var
        checkexp(var, st, errors)
        node.exp._type = var._type
        local fname = var._tag == "Var_Name" and var.name or (var.exp.var.name .. "." .. var.name)
        if types.has_tag(var._type, "Function") then
            local ftype = var._type
            local nparams = #ftype.params
            local args = node.args.args
            local nargs = #args
            local arity = math.max(nparams, nargs)
            for i = 1, arity do
                local arg = args[i]
                local ptype = ftype.params[i]
                local atype
                if not arg then
                    atype = ptype
                else
                    checkexp(arg, st, errors, ptype)
                    ptype = ptype or arg._type
                    args[i] = trycoerce(args[i], ptype, errors)
                    atype = args[i]._type
                end
                if not ptype then
                    ptype = atype
                end
                checkmatch("argument " .. i .. " of call to function '" .. fname .. "'", ptype, atype, errors, node.exp._pos)
            end
            if nargs ~= nparams then
                typeerror(errors, "function " .. fname .. " called with " .. nargs ..
                    " arguments but expects " .. nparams, node._pos)
            end
            assert(#ftype.rettypes == 1)
            node._type = ftype.rettypes[1]
        else
            typeerror(errors, "'%s' is not a function but %s", node._pos, fname, types.tostring(var._type))
            for _, arg in ipairs(node.args.args) do
                checkexp(arg, st, errors)
            end
            node._type = types.Integer
        end
    elseif tag == "Exp_Cast" then
        local l, _ = util.get_line_number(errors.subject, node._pos)
        node._lin = l
        node.target = typefromnode(node.target, errors)
        checkexp(node.exp, st, errors, node.target)
        if not types.coerceable(node.exp._type, node.target) or
          not types.compatible(node.exp._type, node.target) then
            typeerror(errors, "cannot cast '%s' to '%s'", node._pos,
                types.tostring(node.exp._type), types.tostring(node.target))
        end
        node._type = node.target
    else
        error("invalid node tag " .. tag)
    end
end

-- Typechecks a function body
--   node: TopLevel_Func AST node
--   st: symbol table
--   errors: list of compile-time errors
local function checkfunc(node, st, errors)
    local l, _ = util.get_line_number(errors.subject, node._pos)
    node._lin = l
    st:add_symbol("$function", node) -- for return type
    local pnames = {}
    for _, param in ipairs(node.params) do
        checkstat(param, st, errors)
        if pnames[param.name] then
            typeerror(errors, "duplicate parameter '%s' in declaration of function '%s'", node._pos, param.name, node.name)
        else
            pnames[param.name] = true
        end
    end
    assert(#node._type.rettypes == 1)
    local ret = st:with_block(checkstat, node.block, st, errors)
    if not ret and not types.equals(node._type.rettypes[1], types.Nil) then
        typeerror(errors, "function can return nil but return type is not nil", node._pos)
    end
end

-- Third typechecking pass over the module, checks function bodies
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
local function thirdpass(ast, st, errors)
    for _, tlnode in ipairs(ast) do
        if not tlnode._ignore then
            local tag = tlnode._tag
            if tag == "TopLevel_Func" then
                st:with_block(checkfunc, tlnode, st, errors)
            end
        end
    end
end

-- Gets type information for all imported modules and puts
-- it in the symbol table
local function importpass(ast, st, errors, loader)
    for _, tlnode in ipairs(ast) do
        if tlnode._tag == "TopLevel_Import" then
            local name = tlnode.modname
            if st:find_dup(tlnode.localname) then
                typeerror(errors, "duplicate declaration for " .. tlnode.localname, tlnode._pos)
                tlnode._ignore = true
            else
                local modtype, errs = checker.checkimport(name, loader)
                if modtype then
                    tlnode._type = modtype
                    for _, err in ipairs(errs) do
                        table.insert(errors, err)
                    end
                    st:add_symbol(tlnode.localname, tlnode)
                else
                    tlnode._type = types.Nil
                    typeerror(errors, "problem loading module '%s': %s", tlnode._pos, name, errs)
                end
            end
        end
    end
end

function checker.checkimport(modname, loader)
    local ok, type_or_error, errors = loader(modname)
    if not ok then return nil, type_or_error end
    return type_or_error, errors
end

-- Entry point for the typechecker
--   ast: AST for the whole module
--   subject: the string that generated the AST
--   filename: the file name that contains the subject
--   returns true if typechecking succeeds, or false and a list of type errors found
--   annotates the AST with the types of its terms in "_type" fields
--   annotates duplicate top-level declarations with a "_ignore" boolean field
--   loader: the module loader, a function from module name to its AST, code, and filename or nil and an error
function checker.check(modname, ast, subject, filename, loader)
    loader = loader or function () return nil, "you must pass a loder to import modules" end
    local st = symtab.new()
    local errors = {subject = subject, filename = filename}
    importpass(ast, st, errors, loader)
    firstpass(ast, st, errors)
    secondpass(ast, st, errors)
    thirdpass(ast, st, errors)
    return types.maketype(modname, ast), errors
end

return checker
