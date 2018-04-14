#include "tcore.h"

#include "lua.h"
#include "lauxlib.h"

#include "lobject.h"
#include "lstate.h"
#include "ltable.h"
#include "ltm.h"

const char *titan_tag_name(int raw_tag)
{
    if (raw_tag == LUA_TNUMINT) {
        return "integer";
    } else if (raw_tag == LUA_TNUMFLT) {
        return "float";
    } else {
        return ttypename(novariant(raw_tag));
    }
}

void titan_runtime_arity_error(
    lua_State *L,
    int expected,
    int received
){
    luaL_error(
        L,
        "wrong number of arguments to function, expected %d but received %d",
        expected, received
    );
    TITAN_UNREACHABLE;
}

void titan_runtime_argument_type_error(
    lua_State *L,
    const char *param_name,
    int line,
    int expected_tag,
    TValue *slot
){
    const char *expected_type = titan_tag_name(expected_tag);
    const char *received_type = titan_tag_name(rawtt(slot));
    luaL_error(
        L,
        "wrong type for argument %s at line %d, expected %s but found %s",
        param_name, line, expected_type, received_type
    );
    TITAN_UNREACHABLE;
}

void titan_runtime_array_bounds_error(
    lua_State *L,
    int line, int col
){
    luaL_error(
        L,
        "out of bounds (outside array part) at line %d, col %d",
        line, col
    );
    TITAN_UNREACHABLE;
}

void titan_runtime_array_out_of_bounds_read(
    lua_State *L, Table *t, lua_Unsigned ui, int line, int col
){
    luaH_titan_normalize_table(L, t);
    unsigned int asize = t->sizearray;
    if (ui >= asize) {
        titan_runtime_array_bounds_error(L, line, col);
    }
}

void titan_runtime_array_out_of_bounds_write(
    lua_State *L, Table *t, lua_Unsigned ui, int line, int col
){
    luaH_titan_normalize_table(L, t);
    unsigned int asize = t->sizearray;
    if (ui > asize) {
        titan_runtime_array_bounds_error(L, line, col);
    }
    if (ui == asize) {
        asize = (asize == 0 ? 1 : 2*asize);
        luaH_resizearray(L, t, asize);
    }
}

void titan_runtime_array_type_error(
   lua_State *L,
   int line,
   int expected_tag,
   TValue *slot
){
    if (isempty(slot)) {
        luaL_error(
            L,
            "out of bounds (inside array part) at line %d",
            line
        );
        TITAN_UNREACHABLE;
    } else {
        const char *expected_type = titan_tag_name(expected_tag);
        const char *received_type = titan_tag_name(rawtt(slot));
        luaL_error(
            L,
            "wrong type for array element at line %d, expected %s but found %s",
            line, expected_type, received_type
        );
        TITAN_UNREACHABLE;
    }
}

void titan_runtime_function_return_error(
    lua_State *L,
    int line,
    int expected_tag,
    TValue *slot
){
    const char *expected_type = titan_tag_name(expected_tag);
    const char *received_type = titan_tag_name(rawtt(slot));
    luaL_error(
        L,
        "wrong type for function result at line %d, expected %s but found %s",
        line, expected_type, received_type
    );
    TITAN_UNREACHABLE;
}
