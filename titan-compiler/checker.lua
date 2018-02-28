local checker = {}

local location = require "titan-compiler.location"
local symtab = require "titan-compiler.symtab"
local types = require "titan-compiler.types"
local ast = require "titan-compiler.ast"
local util = require "titan-compiler.util"


-- The typechecker works in two passes, the first one just
-- collects type information for top-level functions and variables
-- (and detects duplicate definitions in the top level), while the
-- second pass does the actual typechecking. All typechecked nodes
-- that have a type get a "_type" field with the type. The types
-- themselves are in "types.lua".

local typefromnode
local checkdecl
local checkstat
local checkexp
local checkvar

local function typeerror(errors, fmt, loc, ...)
    local errmsg = location.format_error(loc, "type error: "..fmt, ...)
    table.insert(errors, errmsg)
end

checker.typeerror = typeerror

-- Checks if two types are the same, and logs an error message otherwise
--   term: string describing what is being compared
--   expected: type that is expected
--   found: type that was actually present
--   errors: list of compile-time errors
--   loc: location of the term that is being compared
local function checkmatch(term, expected, found, errors, loc)
    if types.coerceable(found, expected) or not types.compatible(expected, found) then
        local msg = "types in %s do not match, expected %s but found %s"
        msg = string.format(msg, term, types.tostring(expected), types.tostring(found))
        typeerror(errors, msg, loc)
    end
end

-- Converts an AST type declaration into a typechecker type
--   node: AST node
--   errors: list of compile-time errors
--   returns a type (from types.lua)
typefromnode = util.make_visitor({
    ["Ast.TypeNil"] = function(node, st, errors)
        return types.Nil()
    end,

    ["Ast.TypeBoolean"] = function(node, st, errors)
        return types.Boolean()
    end,

    ["Ast.TypeInteger"] = function(node, st, errors)
        return types.Integer()
    end,

    ["Ast.TypeFloat"] = function(node, st, errors)
        return types.Float()
    end,

    ["Ast.TypeString"] = function(node, st, errors)
        return types.String()
    end,

    ["Ast.TypeValue"] = function(node, st, errors)
        return types.Value()
    end,

    ["Ast.TypeName"] = function(node, st, errors)
        local name = node.name
        local sym = st:find_symbol(name)
        if sym then
            if sym._type._tag == "Type.Type" then
                return sym._type.type
            else
                typeerror(errors, "%s isn't a type", node.loc, name)
                return types.Invalid()
            end
        else
            typeerror(errors, "type '%s' not found", node.loc, name)
            return types.Invalid()
        end
    end,

    ["Ast.TypeArray"] = function(node, st, errors)
        return types.Array(typefromnode(node.subtype, st, errors))
    end,

    ["Ast.TypeFunction"] = function(node, st, errors)
        if #node.argtypes ~= 1 then
            error("functions with 0 or 2+ return values are not yet implemented")
        end
        local ptypes = {}
        for _, ptype in ipairs(node.argtypes) do
            table.insert(ptypes, typefromnode(ptype, st, errors))
        end
        local rettypes = {}
        for _, rettype in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rettype, st, errors))
        end
        return types.Function(ptypes, rettypes)
    end,
})

-- tries to coerce node to target type
--    node: expression node
--    target: target type
--    returns node wrapped in a coercion, or original node
local function trycoerce(node, target, errors)
    if types.coerceable(node._type, target) then
        local n = ast.ExpCast(node.loc, node, target)
        n._type = target
        return n
    else
        return node
    end
end

local function trytostr(node)
    local source = node._type
    if source._tag == "Type.Integer" or
       source._tag == "Type.Float" then
        local n = ast.ExpCast(node.loc, node, types.String())
        n._type = types.String()
        return n
    else
        return node
    end
end

--
-- Decl
--

checkdecl = function(node, st, errors)
    st:add_symbol(node.name, node)
    node._type = node._type or typefromnode(node.type, st, errors)
end

--
-- Stat
--

-- Typechecks a repeat/until statement
--   node: StatRepeat AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for repeat/until)
local function checkrepeat(node, st, errors)
    for _, stat in ipairs(node.block.stats) do
        checkstat(stat, st, errors)
    end
    checkexp(node.condition, st, errors, types.Boolean())
    return false
end

-- Typechecks a for loop statement
--   node: StatFor AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for 'for' loop)
local function checkfor(node, st, errors)
    local ftype
    if node.decl.type then
      checkdecl(node.decl, st, errors)
      ftype = node.decl._type
      if ftype._tag ~= "Type.Integer" and
         ftype._tag ~= "Type.Float" then
        typeerror(errors, "type of for control variable " .. node.decl.name .. " must be integer or float", node.decl.loc)
        node.decl._type = types.Invalid()
        ftype = types.Invalid()
      end
      checkexp(node.start, st, errors, ftype)
      node.start = trycoerce(node.start, ftype, errors)
    else
      checkexp(node.start, st, errors)
      ftype = node.start._type
      node.decl._type = ftype
      checkdecl(node.decl, st, errors)
      if ftype._tag ~= "Type.Integer" and
         ftype._tag ~= "Type.Float" then
        typeerror(errors, "type of for control variable " .. node.decl.name .. " must be integer or float", node.decl.loc)
        node.decl._type = types.Invalid()
        ftype = types.Invalid()
      end
    end
    checkmatch("'for' start expression", ftype, node.start._type, errors, node.start.loc)
    checkexp(node.finish, st, errors, ftype)
    node.finish = trycoerce(node.finish, ftype, errors)
    checkmatch("'for' finish expression", ftype, node.finish._type, errors, node.finish.loc)
    if node.inc then
        checkexp(node.inc, st, errors, ftype)
        node.inc = trycoerce(node.inc, ftype, errors)
        checkmatch("'for' step expression", ftype, node.inc._type, errors, node.inc.loc)
    end
    checkstat(node.block, st, errors)
    return false
end

-- Typechecks a block statement
--   node: StatBlock AST node
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
--   node: A DeclDecl or Stat_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for repeat/until)
checkstat = util.make_visitor({
    ["Ast.StatDecl"] = function(node, st, errors)
        if node.decl.type then
          checkdecl(node.decl, st, errors)
          checkexp(node.exp, st, errors, node.decl._type)
        else
          checkexp(node.exp, st, errors)
          node.decl._type = node.exp._type
          checkdecl(node.decl, st, errors)
        end
        node.exp = trycoerce(node.exp, node.decl._type, errors)
        checkmatch("declaration of local variable " .. node.decl.name,
            node.decl._type, node.exp._type, errors, node.decl.loc)
    end,

    ["Ast.StatBlock"] = function(node, st, errors)
        return st:with_block(checkblock, node, st, errors)
    end,

    ["Ast.StatWhile"] = function(node, st, errors)
        checkexp(node.condition, st, errors, types.Boolean())
        st:with_block(checkstat, node.block, st, errors)
    end,

    ["Ast.StatRepeat"] = function(node, st, errors)
        st:with_block(checkrepeat, node, st, errors)
    end,

    ["Ast.StatFor"] = function(node, st, errors)
        st:with_block(checkfor, node, st, errors)
    end,

    ["Ast.StatAssign"] = function(node, st, errors)
        checkvar(node.var, st, errors)
        checkexp(node.exp, st, errors, node.var._type)
        local texp = node.var._type
        if texp._tag == "Type.Module" then
            typeerror(errors, "trying to assign to a module", node.loc)
        elseif texp._tag == "Type.Function" then
            typeerror(errors, "trying to assign to a function", node.loc)
        else
            -- mark this declared variable as assigned to
            if node.var._tag == "Ast.VarName" and node.var._decl then
                node.var._decl._assigned = true
            end
            node.exp = trycoerce(node.exp, node.var._type, errors)
            if node.var._tag ~= "Ast.VarBracket" or node.exp._type._tag ~= "Type.Nil" then
                checkmatch("assignment", node.var._type, node.exp._type, errors, node.var.loc)
            end
        end
    end,

    ["Ast.StatCall"] = function(node, st, errors)
        checkexp(node.callexp, st, errors)
    end,

    ["Ast.StatReturn"] = function(node, st, errors)
        local ftype = st:find_symbol("$function")._type
        assert(#ftype.rettypes == 1)
        local tret = ftype.rettypes[1]
        checkexp(node.exp, st, errors, tret)
        node.exp = trycoerce(node.exp, tret, errors)
        checkmatch("return", tret, node.exp._type, errors, node.exp.loc)
        return true
    end,

    ["Ast.StatIf"] = function(node, st, errors)
        local ret = true
        for _, thn in ipairs(node.thens) do
            checkexp(thn.condition, st, errors, types.Boolean())
            ret = checkstat(thn.block, st, errors) and ret
        end
        if node.elsestat then
            ret = checkstat(node.elsestat, st, errors) and ret
        else
            ret = false
        end
        return ret
    end,
})

--
-- Var
--

-- Typechecks an variable node
--   node: Var_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   annotates the node with its type in a "_type" field
checkvar = util.make_visitor({
    ["Ast.VarName"] = function(node, st, errors, context)
        local decl = st:find_symbol(node.name)
        if not decl then
            local msg = "variable '" .. node.name .. "' not declared"
            typeerror(errors, msg, node.loc)
            node._type = types.Invalid()
        else
            decl._used = true
            node._decl = decl
            node._type = decl._type
        end
    end,

    ["Ast.VarDot"] = function(node, st, errors)
        local var = assert(node.exp.var, "left side of dot is not var")
        checkvar(var, st, errors)
        node.exp._type = var._type
        local vartype = var._type
        if vartype._tag == "Type.Module" then
            local mod = vartype
            if not mod.members[node.name] then
                typeerror(errors, "variable '%s' not found inside module '%s'",
                          node.loc, node.name, mod.name)
            else
                local decl = mod.members[node.name]
                node._decl = decl
                node._type = decl
            end
        elseif vartype._tag == "Type.Type" then
            local typ = vartype.type
            if typ._tag == "Type.Record" then
                if node.name == "new" then
                    local params = {}
                    for _, field in ipairs(typ.fields) do
                        table.insert(params, field.type)
                    end
                    node._decl = typ
                    node._type = types.Function(params, {typ})
                else
                    typeerror(errors, "trying to access invalid record " ..
                              "member '%s'", node.loc, node.name)
                end
            else
                typeerror(errors, "invalid access to type '%s'", node.loc,
                          types.tostring(type))
            end
        elseif vartype._tag == "Type.Record" then
            for _, field in ipairs(vartype.fields) do
                if field.name == node.name then
                    node._type = field.type
                    break
                end
            end
            if not node._type then
                typeerror(errors, "field '%s' not found in record '%s'",
                          node.loc, node.name, vartype.name)
            end
        else
            typeerror(errors, "trying to access a member of value of type '%s'",
                      node.loc, types.tostring(vartype))
        end
        node._type = node._type or types.Invalid()
    end,

    ["Ast.VarBracket"] = function(node, st, errors, context)
        checkexp(node.exp1, st, errors, context and types.Array(context))
        if node.exp1._type._tag ~= "Type.Array" then
            typeerror(errors, "array expression in indexing is not an array but "
                .. types.tostring(node.exp1._type), node.exp1.loc)
            node._type = types.Invalid()
        else
            node._type = node.exp1._type.elem
        end
        checkexp(node.exp2, st, errors, types.Integer())
        -- always try to coerce index to integer
        node.exp2 = trycoerce(node.exp2, types.Integer(), errors)
        checkmatch("array indexing", types.Integer(), node.exp2._type, errors, node.exp2.loc)
    end,
})

--
-- Exp
--

-- Typechecks an expression
--   node: Exp_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   annotates the node with its type in a "_type" field
checkexp = util.make_visitor({
    ["Ast.ExpNil"] = function(node)
        node._type = types.Nil()
    end,

    ["Ast.ExpBool"] = function(node)
        node._type = types.Boolean()
    end,

    ["Ast.ExpInteger"] = function(node)
        node._type = types.Integer()
    end,

    ["Ast.ExpFloat"] = function(node)
        node._type = types.Float()
    end,

    ["Ast.ExpString"] = function(node)
        node._type = types.String()
    end,

    ["Ast.ExpInitList"] = function(node, st, errors, context)
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
            local etype = econtext or etypes[1] or types.Integer()
            node._type = types.Array(etype)
            for i, field in ipairs(node.fields) do
                field.exp = trycoerce(field.exp, etype, errors)
                local exp = field.exp
                checkmatch("array initializer at position " .. i, etype,
                           exp._type, errors, exp.loc)
            end
        else
            node._type = types.InitList(etypes)
        end
    end,

    ["Ast.ExpVar"] = function(node, st, errors, context)
        checkvar(node.var, st, errors, context)
        local texp = node.var._type
        if texp._tag == "Type.Module" then
            typeerror(errors, "trying to access module '%s' as a first-class value", node.loc, node.var.name)
            node._type = types.Invalid()
        elseif texp._tag == "Type.Function" then
            typeerror(errors, "trying to access a function as a first-class value", node.loc)
            node._type = types.Invalid()
        else
            node._type = texp
        end
    end,

    ["Ast.ExpUnop"] = function(node, st, errors, context)
        local op = node.op
        checkexp(node.exp, st, errors)
        local texp = node.exp._type
        local loc = node.loc
        if op == "#" then
            if texp._tag ~= "Type.Array" and texp._tag ~= "Type.String" then
                typeerror(errors, "trying to take the length of a " .. types.tostring(texp) .. " instead of an array or string", loc)
            end
            node._type = types.Integer()
        elseif op == "-" then
            if texp._tag ~= "Type.Integer" and texp._tag ~= "Type.Float" then
                typeerror(errors, "trying to negate a " .. types.tostring(texp) .. " instead of a number", loc)
            end
            node._type = texp
        elseif op == "~" then
            -- always tries to coerce floats to integer
            node.exp = node.exp._type._tag == "Type.Float" and trycoerce(node.exp, types.Integer(), errors) or node.exp
            texp = node.exp._type
            if texp._tag ~= "Type.Integer" then
                typeerror(errors, "trying to bitwise negate a " .. types.tostring(texp) .. " instead of an integer", loc)
            end
            node._type = types.Integer()
        elseif op == "not" then
            -- always coerces other values to a boolean
            node.exp = trycoerce(node.exp, types.Boolean(), errors)
            node._type = types.Boolean()
        else
            error("invalid unary operation " .. op)
        end
    end,

    ["Ast.ExpConcat"] = function(node, st, errors, context)
        for i, exp in ipairs(node.exps) do
            checkexp(exp, st, errors, types.String())
            -- always tries to coerce numbers to string
            exp = trytostr(exp)
            node.exps[i] = exp
            local texp = exp._type
            if texp._tag == "Type.Value" then
                typeerror(errors, "cannot concatenate with value of type 'value'", exp.loc)
            elseif texp._tag ~= "Type.String" then
                typeerror(errors, "cannot concatenate with " .. types.tostring(texp) .. " value", exp.loc)
            end
        end
        node._type = types.String()
    end,

    ["Ast.ExpBinop"] = function(node, st, errors, context)
        local op = node.op
        checkexp(node.lhs, st, errors)
        local tlhs = node.lhs._type
        checkexp(node.rhs, st, errors)
        local trhs = node.rhs._type
        local loc = node.loc
        if op == "==" or op == "~=" then
            -- tries to coerce to value if either side is value
            if tlhs._tag == "Type.Value" or trhs._tag == "Type.Value" then
                node.lhs = trycoerce(node.lhs, types.Value(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value(), errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if either side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if not types.compatible(tlhs, trhs) then
                typeerror(errors, "trying to compare values of different types: " ..
                    types.tostring(tlhs) .. " and " .. types.tostring(trhs), loc)
            end
            node._type = types.Boolean()
        elseif op == "<" or op == ">" or op == "<=" or op == ">=" then
            -- tries to coerce to value if either side is value
            if tlhs._tag == "Type.Value" or trhs._tag == "Type.Value" then
                node.lhs = trycoerce(node.lhs, types.Value(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value(), errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if either side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if not types.equals(tlhs, trhs) then
                if tlhs._tag ~= "Type.Integer" and tlhs._tag ~= "Type.Float" and trhs._tag == "Type.Integer" or trhs._tag == "Type.Float" then
                    typeerror(errors, "left hand side of relational expression is a " .. types.tostring(tlhs) .. " instead of a number", loc)
                elseif trhs._tag ~= "Type.Integer" and trhs._tag ~= "Type.Float" and tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float" then
                    typeerror(errors, "right hand side of relational expression is a " .. types.tostring(trhs) .. " instead of a number", loc)
                elseif tlhs._tag ~= "Type.String" and trhs._tag == "Type.String" then
                    typeerror(errors, "left hand side of relational expression is a " .. types.tostring(tlhs) .. " instead of a string", loc)
                elseif trhs._tag ~= "Type.String" and tlhs._tag == "Type.String" then
                    typeerror(errors, "right hand side of relational expression is a " .. types.tostring(trhs) .. " instead of a string", loc)
                else
                    typeerror(errors, "trying to use relational expression with " .. types.tostring(tlhs) .. " and " .. types.tostring(trhs), loc)
                end
            else
                if tlhs._tag ~= "Type.Integer" and tlhs._tag ~= "Type.Float" and tlhs._tag ~= "Type.String" then
                    typeerror(errors, "trying to use relational expression with two " .. types.tostring(tlhs) .. " values", loc)
                end
            end
            node._type = types.Boolean()
        elseif op == "+" or op == "-" or op == "*" or op == "%" or op == "//" then
            if not (tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float") then
                typeerror(errors, "left hand side of arithmetic expression is a " .. types.tostring(tlhs) .. " instead of a number", loc)
            end
            if not (trhs._tag == "Type.Integer" or trhs._tag == "Type.Float") then
                typeerror(errors, "right hand side of arithmetic expression is a " .. types.tostring(trhs) .. " instead of a number", loc)
            end
            -- tries to coerce to value if either side is value
            if tlhs._tag == "Type.Value" or trhs._tag == "Type.Value" then
                node.lhs = trycoerce(node.lhs, types.Value(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value(), errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if either side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if tlhs._tag == "Type.Float" and trhs._tag == "Type.Float" then
                node._type = types.Float()
            elseif tlhs._tag == "Type.Integer" and trhs._tag == "Type.Integer" then
                node._type = types.Integer()
            else
                -- error
                node._type = types.Invalid()
            end
        elseif op == "/" or op == "^" then
            if tlhs._tag == "Type.Integer" then
                -- always tries to coerce to float
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
            end
            if trhs._tag == "Type.Integer" then
                -- always tries to coerce to float
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if tlhs._tag ~= "Type.Float" then
                typeerror(errors, "left hand side of arithmetic expression is a " .. types.tostring(tlhs) .. " instead of a number", loc)
            end
            if trhs._tag ~= "Type.Float" then
                typeerror(errors, "right hand side of arithmetic expression is a " .. types.tostring(trhs) .. " instead of a number", loc)
            end
            node._type = types.Float()
        elseif op == "and" or op == "or" then
            -- tries to coerce to boolean if other side is boolean
            if tlhs._tag == "Type.Boolean" or trhs._tag == "Type.Boolean" then
                node.lhs = trycoerce(node.lhs, types.Boolean(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Boolean(), errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to value if other side is value
            if tlhs._tag == "Type.Value" or trhs._tag == "Type.Value" then
                node.lhs = trycoerce(node.lhs, types.Value(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value(), errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if other side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
              node.lhs = trycoerce(node.lhs, types.Float(), errors)
              tlhs = node.lhs._type
              node.rhs = trycoerce(node.rhs, types.Float(), errors)
              trhs = node.rhs._type
            end
            if not types.compatible(tlhs, trhs) then
              typeerror(errors, "left hand side of logical expression is a " ..
               types.tostring(tlhs) .. " but right hand side is a " ..
               types.tostring(trhs), loc)
            end
            node._type = tlhs
        elseif op == "|" or op == "&" or op == "<<" or op == ">>" then
            -- always tries to coerce floats to integer
            node.lhs = node.lhs._type._tag == "Type.Float" and trycoerce(node.lhs, types.Integer(), errors) or node.lhs
            tlhs = node.lhs._type
            -- always tries to coerce floats to integer
            node.rhs = node.rhs._type._tag == "Type.Float" and trycoerce(node.rhs, types.Integer(), errors) or node.rhs
            trhs = node.rhs._type
            if tlhs._tag ~= "Type.Integer" then
                typeerror(errors, "left hand side of arithmetic expression is a " .. types.tostring(tlhs) .. " instead of a number", loc)
            end
            if trhs._tag ~= "Type.Integer" then
                typeerror(errors, "right hand side of arithmetic expression is a " .. types.tostring(trhs) .. " instead of a number", loc)
            end
            node._type = types.Integer()
        else
            error("invalid binary operation " .. op)
        end
    end,

    ["Ast.ExpCall"] = function(node, st, errors, context)
        assert(node.exp._tag == "Ast.ExpVar", "function calls are first-order only!")
        local var = node.exp.var
        checkvar(var, st, errors)
        node.exp._type = var._type
        local fname = var._tag == "Ast.VarName" and var.name or (var.exp.var.name .. "." .. var.name)
        if var._type._tag == "Type.Function" then
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
                checkmatch("argument " .. i .. " of call to function '" .. fname .. "'", ptype, atype, errors, node.exp.loc)
            end
            if nargs ~= nparams then
                typeerror(errors, "function " .. fname .. " called with " .. nargs ..
                    " arguments but expects " .. nparams, node.loc)
            end
            assert(#ftype.rettypes == 1)
            node._type = ftype.rettypes[1]
        else
            typeerror(errors, "'%s' is not a function but %s", node.loc, fname, types.tostring(var._type))
            for _, arg in ipairs(node.args.args) do
                checkexp(arg, st, errors)
            end
            node._type = types.Invalid()
        end
    end,

    ["Ast.ExpCast"] = function(node, st, errors, context)
        node.target = typefromnode(node.target, st, errors)
        checkexp(node.exp, st, errors, node.target)
        if not types.coerceable(node.exp._type, node.target) or
          not types.compatible(node.exp._type, node.target) then
            typeerror(errors, "cannot cast '%s' to '%s'", node.loc,
                types.tostring(node.exp._type), types.tostring(node.target))
        end
        node._type = node.target
    end,
})

--
-- TopLevel
--

-- Typechecks a function body
--   node: TopLevelFunc AST node
--   st: symbol table
--   errors: list of compile-time errors
local function checkfunc(node, st, errors)
    st:add_symbol("$function", node) -- for return type
    local ptypes = node._type.params
    local pnames = {}
    for i, param in ipairs(node.params) do
        st:add_symbol(param.name, param)
        param._type = ptypes[i]
        if pnames[param.name] then
            typeerror(errors, "duplicate parameter '%s' in declaration of function '%s'", node.loc, param.name, node.name)
        else
            pnames[param.name] = true
        end
    end
    assert(#node._type.rettypes == 1)
    local ret = st:with_block(checkstat, node.block, st, errors)
    if not ret and node._type.rettypes[1]._tag ~= "Type.Nil" then
        typeerror(errors, "function can return nil but return type is not nil", node.loc)
    end
end

-- Checks function bodies
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
local function checkbodies(ast, st, errors)
    for _, node in ipairs(ast) do
        if not node._ignore and
           node._tag == "Ast.TopLevelFunc" then
            st:with_block(checkfunc, node, st, errors)
        end
    end
end

local function isconstructor(node)
    return node.var and node.var._decl and node.var._decl._tag == "Type.Record"
end

-- Verify if an expression is constant
local function isconst(node)
    local tag = node._tag
    if tag == "Ast.ExpNil" or
       tag == "Ast.ExpBool" or
       tag == "Ast.ExpInteger" or
       tag == "Ast.ExpFloat" or
       tag == "Ast.ExpString" then
        return true

    elseif tag == "Ast.ExpInitList" then
        local const = true
        for _, field in ipairs(node.fields) do
            const = const and isconst(field.exp)
        end
        return const

    elseif tag == "Ast.ExpCall" then
        if isconstructor(node.exp) then
            local const = true
            for _, arg in ipairs(node.args) do
                const = const and isconst(arg)
            end
            return const
        else
            return false
        end

    elseif tag == "Ast.ExpVar" then
        return false

    elseif tag == "Ast.ExpConcat" then
        local const = true
        for _, exp in ipairs(node.exps) do
            const = const and isconst(exp)
        end
        return const

    elseif tag == "Ast.ExpUnop" then
        return isconst(node.exp)

    elseif tag == "Ast.ExpBinop" then
        return isconst(node.lhs) and isconst(node.rhs)

    elseif tag == "Ast.ExpCast" then
        return isconst(node.exp)

    else
        error("impossible")
    end
end

-- Return the name given the toplevel node
local function toplevel_name(node)
    local tag = node._tag
    if tag == "Ast.TopLevelImport" then
        return node.localname
    elseif tag == "Ast.TopLevelVar" then
        return node.decl.name
    elseif tag == "Ast.TopLevelFunc" or
           tag == "Ast.TopLevelRecord" then
        return node.name
    else
        error("tag not found " .. tag)
    end
end

-- Typecheck the toplevel node
local toplevel_visitor = util.make_visitor({
    ["Ast.TopLevelImport"] = function(node, st, errors, loader)
        local modtype, errs = checker.checkimport(node.modname, loader)
        if modtype then
            node._type = modtype
            for _, err in ipairs(errs) do
                table.insert(errors, err)
            end
        else
            node._type = types.Nil()
            typeerror(errors, "problem loading module '%s': %s",
                      node.loc, node.modname, errs)
        end
    end,

    ["Ast.TopLevelVar"] = function(node, st, errors)
        if node.decl.type then
            node._type = typefromnode(node.decl.type, st, errors)
            checkexp(node.value, st, errors, node._type)
            node.value = trycoerce(node.value, node._type, errors)
            checkmatch("declaration of module variable " .. node.decl.name,
                       node._type, node.value._type, errors, node.loc)
        else
            checkexp(node.value, st, errors)
            node._type = node.value._type
        end
        if not isconst(node.value) then
            local msg = "top level variable initialization must be constant"
            typeerror(errors, msg, node.value.loc)
        end
    end,

    ["Ast.TopLevelFunc"] = function(node, st, errors)
        if #node.rettypes ~= 1 then
            error("functions with 0 or 2+ return values are not yet implemented")
        end
        local ptypes = {}
        for _, pdecl in ipairs(node.params) do
            table.insert(ptypes, typefromnode(pdecl.type, st, errors))
        end
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        node._type = types.Function(ptypes, rettypes)
    end,

    ["Ast.TopLevelRecord"] = function(node, st, errors)
        local fields = {}
        for _, field in ipairs(node.fields) do
            local typ = typefromnode(field.type, st, errors)
            table.insert(fields, {type = typ, name = field.name})
        end
        node._type = types.Type(types.Record(node.name, fields))
    end,
})

-- Colect type information of toplevel nodes
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
--   annotates the top-level nodes with their types in a "_type" field
--   annotates whether a top-level declaration is duplicated with a "_ignore"
--   field
local function checktoplevel(ast, st, errors, loader)
    for _, node in ipairs(ast) do
        local name = toplevel_name(node)
        local dup = st:find_dup(name)
        if dup then
            typeerror(errors,
                "duplicate declaration for %s, previous one at line %d",
                node.loc, name, dup.loc.line)
            node._ignore = true
        else
            toplevel_visitor(node, st, errors, loader)
            st:add_symbol(name, node)
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
--   loader: the module loader, a function from module name to its AST, code,
--   and filename or nil and an error
--
--   returns true if typechecking succeeds, or false and a list of type errors
--   found
--   annotates the AST with the types of its terms in "_type" fields
--   annotates duplicate top-level declarations with a "_ignore" boolean field
function checker.check(modname, ast, subject, filename, loader)
    loader = loader or function ()
        return nil, "you must pass a loader to import modules"
    end
    local st = symtab.new()
    local errors = {subject = subject, filename = filename}
    checktoplevel(ast, st, errors, loader)
    checkbodies(ast, st, errors)
    return types.makemoduletype(modname, ast), errors
end

return checker
