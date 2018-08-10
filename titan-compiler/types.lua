local typedecl = require 'titan-compiler.typedecl'

local types = typedecl("Type", {
    Types = {
        Invalid     = {},
        Nil         = {},
        Boolean     = {},
        Integer     = {},
        Float       = {},
        String      = {},
        Value       = {},
        Function    = {"params", "rettypes", "vararg"},
        Array       = {"elem"},
        Map         = {"keys", "values"},
        Record      = {"name", "fields", "functions", "methods"},
        Nominal     = {"fqtn"},
        Field       = {"fqtn", "name", "type", "index"},
        Method      = {"fqtn", "name", "params", "rettypes"},
        ForeignModule = {"name", "members"},
        ModuleMember = {"modname", "name", "type"},
        ModuleVariable = {"modname", "name", "type"},
        StaticMethod = {"fqtn", "name", "params", "rettypes"},
        Option       = {"base"}
    }
})

-- Registry for nominal types
-- Keys are canonical FQTNs (fully qualified type names)
-- Values are types
types.registry = {}

function types.is_basic(t)
    local tag = t._tag
    return tag == "Type.Nil" or
           tag == "Type.Boolean" or
           tag == "Type.Integer" or
           tag == "Type.Float" or
           tag == "Type.String" or
           tag == "Type.Value"
end

function types.is_gc(t)
    local tag = t._tag
    return tag == "Type.String" or
           tag == "Type.Value" or
           tag == "Type.Function" or
           tag == "Type.Array" or
           tag == "Type.Map" or
           tag == "Type.Record" or
           tag == "Type.Interface" or
           tag == "Type.Nominal" or
           (tag == "Type.Option" and types.is_gc(t.base))
end

-- XXX this should be inside typedecl call
-- constructors shouldn't do more than initalize members
-- XXX this should not be a type. This makes it possible to
-- construct nonsense things like a function type that returns
-- a module type
function types.Module(modname, members)
    for _, member in ipairs(members) do
        members[member.name] = member
    end
    return { _tag = "Type.Module", name = modname,
        prefix = modname:gsub("[%-.]", "_") .. "_",
        file = modname:gsub("[.]", "/") .. ".so",
        members = members }
end

--- Check if two pointer types are different and can be coerced.
local function can_coerce_pointer(source, target)
    if types.equals(source, target) then
        return false
    elseif target.type._tag == "Type.Nil" then
        -- all pointers are convertible to void*
        if source._tag == "Type.String" then
            return true
        elseif source.tag == "Type.Nil" then
            return true
        elseif source._tag == "Type.Pointer" then
            return true
        end
    end
    return false
end

local function is_void_pointer(typ)
    return typ._tag == "Type.Pointer" and typ.type._tag == "Type.Nil"
end

-- Returns true if type always holds truthy values
function types.is_truthy(typ)
    local tag = typ._tag
    return tag ~= "Type.Nil" and tag ~= "Type.Value" and tag ~= "Type.Option"
        and tag ~= "Type.Pointer" and tag ~= "Type.Boolean"
end

-- Returns true if type always holds falsy values
function types.is_falsy(typ)
    return typ._tag == "Type.Nil"
end

function types.explicitly_coerceable(source, target)
    return is_void_pointer(source) and target._tag == "Type.String"
end

function types.coerceable(source, target)
    return (target._tag == "Type.Pointer" and
            can_coerce_pointer(source, target)) or

           (source._tag == "Type.Integer" and
            target._tag == "Type.Float") or

           (source._tag == "Type.Float" and
            target._tag == "Type.Integer") or

           (target._tag == "Type.Boolean" and
            source._tag ~= "Type.Boolean") or

           (target._tag == "Type.Value" and
            source._tag ~= "Type.Value") or

           (source._tag == "Type.Value" and
            target._tag ~= "Type.Value") or

           (target._tag == "Type.Option" and
            types.equals(source, target.base)) or

           (source._tag == "Type.Option" and
            types.equals(target, source.base)) or

           (target._tag == "Type.Option" and
            source._tag == "Type.Nil") or

           (target._tag == "Type.Option" and
            source._tag == "Type.Option" and
            types.coerceable(source.base, target.base)) or

           (target._tag == "Type.Option" and
            source._tag ~= "Type.Option" and
            types.coerceable(source, target.base)) or

           (source._tag == "Type.Option" and
            target._tag ~= "Type.Option" and
            types.coerceable(target, source.base))

end

-- The type consistency relation, a-la gradual typing
function types.compatible(t1, t2)
    if types.equals(t1, t2) then
        return true
    elseif t1._tag == "Type.Typedef" then
        return types.compatible(t1._type, t2)
    elseif t2._tag == "Type.Typedef" then
        return types.compatible(t1, t2._type)
    elseif t1._tag == "Type.Pointer" and t2._tag == "Type.Nil" then
        return true -- nullable pointer
    elseif t1._tag == "Type.Nil" and t2._tag == "Type.Pointer" then
        return true -- nullable pointer
    elseif types.explicitly_coerceable(t1, t2) then
        return true
    elseif t1._tag == "Type.Value" or t2._tag == "Type.Value" then
        return true
    elseif t1._tag == "Type.Array" and t2._tag == "Type.Array" then
        return types.compatible(t1.elem, t2.elem)
    elseif t1._tag == "Type.Map" and t2._tag == "Type.Map" then
        return types.compatible(t1.keys, t2.keys) and
               types.compatible(t1.values, t2.values)
    elseif t1._tag == "Type.Nominal" and t2._tag == "Type.Nominal" then
        return t1.fqtn == t2.fqtn
    elseif t1._tag == "Type.Function" and t2._tag == "Type.Function" then
        if #t1.params ~= #t2.params then
            return false
        end

        for i = 1, #t1.params do
            if not types.compatible(t1.params[i], t2.params[i]) then
                return false
            end
        end

        if #t1.rettypes ~= #t2.rettypes then
            return false
        end

        for i = 1, #t1.rettypes do
            if not types.compatible(t1.rettypes[i], t2.rettypes[i]) then
                return false
            end
        end

        return true
    else
        return false
    end
end

function types.equals(t1, t2)
    local tag1, tag2 = t1._tag, t2._tag
    if tag1 == "Type.Array" and tag2 == "Type.Array" then
        return types.equals(t1.elem, t2.elem)
    elseif tag1 == "Type.Map" and tag2 == "Type.Map" then
        return types.equals(t1.keys, t2.keys) and
               types.equals(t1.values, t2.values)
    elseif tag1 == "Type.Pointer" and tag2 == "Type.Pointer" then
        return types.equals(t1.type, t2.type)
    elseif tag1 == "Type.Typedef" and tag2 == "Type.Typedef" then
        return t1.name == t2.name
    elseif tag1 == "Type.Function" and tag2 == "Type.Function" then
        if #t1.params ~= #t2.params then
            return false
        end

        for i = 1, #t1.params do
            if not types.equals(t1.params[i], t2.params[i]) then
                return false
            end
        end

        if #t1.rettypes ~= #t2.rettypes then
            return false
        end

        for i = 1, #t1.rettypes do
            if not types.equals(t1.rettypes[i], t2.rettypes[i]) then
                return false
            end
        end

        return true
    elseif tag1 == "Type.Nominal" and tag2 == "Type.Nominal" then
        return t1.fqtn == t2.fqtn
    elseif tag1 == "Type.Option" and tag2 == "Type.Option" then
        return types.equals(t1.base, t2.base)
    elseif tag1 == tag2 then
        return true
    else
        return false
    end
end

function types.tostring(t)
    local tag = t._tag
    if     tag == "Type.Integer"     then return "integer"
    elseif tag == "Type.Boolean"     then return "boolean"
    elseif tag == "Type.String"      then return "string"
    elseif tag == "Type.Nil"         then return "nil"
    elseif tag == "Type.Float"       then return "float"
    elseif tag == "Type.Value"       then return "value"
    elseif tag == "Type.Invalid"     then return "invalid type"
    elseif tag == "Type.Array" then
        return "{ " .. types.tostring(t.elem) .. " }"
    elseif tag == "Type.Map" then
        return "{ " .. types.tostring(t.keys) .. " : " .. types.tostring(t.values) .. " }"
    elseif tag == "Type.Pointer" then
        if is_void_pointer(t) then
            return "void pointer"
        else
            return "pointer to " .. types.tostring(t.type)
        end
    elseif tag == "Type.Typedef" then
        return t.name
    elseif tag == "Type.Function" then
        local out = {"("}
        local ptypes = {}
        for _, param in ipairs(t.params) do
            table.insert(ptypes, types.tostring(param))
        end
        table.insert(out, table.concat(ptypes, ", "))
        table.insert(out, ")")
        local rtypes = {}
        for _, rettype in ipairs(t.rettypes) do
            table.insert(rtypes, types.tostring(rettype))
        end
        if #rtypes == 1 then
            table.insert(out, " -> ")
            table.insert(out, rtypes[1])
        elseif #rtypes > 1 then
            table.insert(out, " -> (")
            table.insert(out, table.concat(rtypes), ", ")
            table.insert(out, ")")
        end
        return table.concat(out)
    elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
        local out = {t.fqtn,
             tag == "Type.Method" and ":" or ".",
             t.name, "("}
        local ptypes = {}
        for _, param in ipairs(t.params) do
            table.insert(ptypes, types.tostring(param))
        end
        table.insert(out, table.concat(ptypes, ", "))
        table.insert(out, ")")
        local rtypes = {}
        for _, rettype in ipairs(t.rettypes) do
            table.insert(rtypes, types.tostring(rettype))
        end
        if #rtypes == 1 then
            table.insert(out, ": ")
            table.insert(out, rtypes[1])
        elseif #rtypes > 1 then
            table.insert(out, ": (")
            table.insert(out, table.concat(rtypes), ", ")
            table.insert(out, ")")
        end
        return table.concat(out)
    elseif tag == "Type.Record" then
        return t.name
    elseif tag == "Type.Nominal" then
        return t.fqtn
    elseif tag == "Type.Option" then
        return types.tostring(t.base) .. "?"
    else
        error("impossible: " .. tostring(tag))
    end
end

function types.serialize(t)
    local tag = t._tag
    if tag == "Type.Array" then
        return "Array(" ..types.serialize(t.elem) .. ")"
    elseif tag == "Type.Map" then
        return "Map(" .. types.serialize(t.keys) .. ", " .. types.serialize(t.values) .. ")"
    elseif tag == "Type.ModuleMember" then
        return "ModuleMember('" .. t.modname .. "', '" ..
            t.name .. "', " .. types.serialize(t.type) .. ")"
    elseif tag == "Type.ModuleVariable" then
        return "ModuleVariable('" .. t.modname .. "', '" ..
            t.name .. "', " .. types.serialize(t.type) .. ")"
    elseif tag == "Type.Module" then
        local members = {}
        for _, member in ipairs(t.members) do
            table.insert(members, types.serialize(member))
        end
        return "Module(" ..
            "'" .. t.name .. "'" .. "," ..
            "{" .. table.concat(members, ",") .. "}" ..
            ")"
    elseif tag == "Type.Function" then
        local ptypes = {}
        for _, pt in ipairs(t.params) do
            table.insert(ptypes, types.serialize(pt))
        end
        local rettypes = {}
        for _, rt in ipairs(t.rettypes) do
            table.insert(rettypes, types.serialize(rt))
        end
        return "Function(" ..
            "{" .. table.concat(ptypes, ",") .. "}" .. "," ..
            "{" .. table.concat(rettypes, ",") .. "}" .. "," ..
            tostring(t.vararg) .. ")"
    elseif tag == "Type.Nominal" then
        return "Nominal('" .. t.fqtn .. "')"
    elseif tag == "Type.Field" then
        return "Field('" .. t.fqtn .. "', '" ..
             t.name .. "', " .. types.serialize(t.type) ..
             ", " .. tostring(t.index) .. ")"
    elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
        local ptypes = {}
        for _, pt in ipairs(t.params) do
            table.insert(ptypes, types.serialize(pt))
        end
        local rettypes = {}
        for _, rt in ipairs(t.rettypes) do
            table.insert(rettypes, types.serialize(rt))
        end
        return (tag == "Type.Method" and "Method('" or "StaticMethod('") ..
            t.fqtn .. "', '" .. t.name .. "'," ..
            "{" .. table.concat(ptypes, ",") .. "}" .. "," ..
            "{" .. table.concat(rettypes, ",") .. "})"
    elseif tag == "Type.Record" then
        local functions, fields, methods = {}, {}, {}
        for _, field in ipairs(t.fields) do
            table.insert(fields, types.serialize(field))
        end
        for name, method in pairs(t.methods) do
            table.insert(methods, name .. " = " .. types.serialize(method))
        end
        for name, func in pairs(t.functions) do
            table.insert(functions, name .. " = " .. types.serialize(func))
        end
        return "Record('" .. t.name ..
            "',{" .. table.concat(fields, ",") ..
            "},{" ..table.concat(functions, ",") .. "}" .. "," ..
            "{" .. table.concat(methods, ",") .. "}" ..
            ")"
    elseif tag == "Type.Option" then
        return "Option(" .. types.serialize(t.base) .. ")"
    elseif tag == "Type.Integer"     then return "Integer()"
    elseif tag == "Type.Boolean"     then return "Boolean()"
    elseif tag == "Type.String"      then return "String()"
    elseif tag == "Type.Nil"         then return "Nil()"
    elseif tag == "Type.Float"       then return "Float()"
    elseif tag == "Type.Value"       then return "Value()"
    elseif tag == "Type.Invalid"     then return "Invalid()"
    else
        error("invalid tag " .. tag)
    end
end

return types
