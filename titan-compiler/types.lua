
local types = {}

function types.Function(ptypes, rettypes)
    return { _tag = "Function", params = ptypes, rettypes = rettypes }
end

function types.Array(etype)
    return { _tag = "Array", elem = etype }
end

function types.InitList(elems)
    return { _tag = "InitList", elems = elems }
end

function types.Module(modname, members)
    return { _tag = "Module", name = modname,
        prefix = modname:gsub("[%-.]", "_") .. "_",
        file = modname:gsub("[.]", "/") .. ".so",
        members = members }
end

local base_types = { "Integer", "Boolean", "String", "Nil", "Float", "Value" }

for _, t in ipairs(base_types) do
    types[t] = { _tag = t }
    base_types[string.lower(t)] = types[t]
end

function types.Base(name)
    return base_types[name]
end

function types.has_tag(t, name)
    return t._tag == name
end

function types.is_gc(t)
    return t._tag == "String" or t._tag == "Array" or t._tag == "Value"
end

function types.coerceable(source, target)
    return (types.equals(source, types.Integer) and
            types.equals(target, types.Float)) or
           (types.equals(source, types.Float) and
            types.equals(target, types.Integer)) or
           (types.equals(target, types.Boolean) and
            not types.equals(source, types.Boolean)) or
           (types.equals(target, types.Value) and
            not types.equals(source, types.Value)) or
           (types.equals(source, types.Value) and
            not types.equals(target, types.Value))
end

function types.compatible(t1, t2)
    if types.equals(t1, t2) then
        return true
    elseif t1._tag == "Value" or t2._tag == "Value" then
        return true
    elseif t1._tag == "Array" and t2._tag == "Array" then
        return types.compatible(t1.elem, t2.elem)
    elseif t1._tag == "Function" and t2._tag == "Function" then
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
    if tag1 == "Array" and tag2 == "Array" then
        return types.equals(t1.elem, t2.elem)
    elseif tag1 == "Function" and tag2 == "Function" then
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
    elseif tag1 == tag2 then
        return true
    else
        return false
    end
end

-- Human-friendly representation of a a function type's
-- parameter or return type list
local function typelist_tostring(ts)
    if #ts == 1 then
        return types.tostring(ts[1])
    else
        local ss = {}
        for _, t in ipairs(ts) do
            table.insert(ss, types.tostring(t))
        end
        return "(" .. table.concat(ss, ",") .. ")"
    end
end

function types.tostring(t)
    local tag = t._tag
    if tag == "Array" then
        return "{ " .. types.tostring(t.elem) .. " }"
    elseif tag == "Function" then
        local ptypes   = typelist_tostring(t.params)
        local rettypes = typelist_tostring(t.rettypes)
        return ptypes .. ' -> ' .. rettypes
    else
        return string.lower(tag)
    end
end

-- Builds a type for the module from the types of its public members
--   ast: AST for the module
--   returns "Module" type
function types.maketype(modname, ast)
    local members = {}
    for _, tlnode in ipairs(ast) do
        if tlnode._tag ~= "TopLevel_Import" and not tlnode.islocal and not tlnode._ignore then
            local tag = tlnode._tag
            if tag == "TopLevel_Func" then
                members[tlnode.name] = tlnode._type
            elseif tag == "TopLevel_Var" then
                members[tlnode.decl.name] = tlnode._type
            end
        end
    end
    return types.Module(modname, members)
end

function types.serialize(t)
    local tag = t._tag
    if tag == "Array" then
        return "Array(" ..types.serialize(t.elem) .. ")"
    elseif tag == "Module" then
        local members = {}
        for name, member in pairs(t.members) do
            table.insert(members, name .. " = " .. types.serialize(member))
        end
        return "Module(" ..
            "'" .. t.name .. "'" .. "," ..
            "{" .. table.concat(members, ",") .. "}" ..
            ")"
    elseif tag == "Function" then
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
            "{" .. table.concat(rettypes, ",") .. "}" ..
            ")"
    else
        return tag
    end
end

return types
