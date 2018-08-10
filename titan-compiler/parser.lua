local parser = {}

local re = require "relabel"
local inspect = require "inspect"

local ast = require "titan-compiler.ast"
local lexer = require "titan-compiler.lexer"
local location = require "titan-compiler.location"
local syntax_errors = require "titan-compiler.syntax_errors"

-- File name of the file that is currently being parsed.
-- Since this is a global the parser is not reentrant but we couldn't think of
-- a better way yet. (If only lpeg.re had Carg...)
local THIS_FILENAME = nil

--
-- Functions used by the PEG grammar
--

local defs = {}

for tokname, tokpat in pairs(lexer) do
    defs[tokname] = tokpat
end

for tag, cons in pairs(ast) do
    defs[tag] = cons
end

function defs.get_loc(s, pos)
    return true, location.from_pos(THIS_FILENAME, s, pos)
end

function defs.totrue()
    return true
end

function defs.tofalse()
    return false
end

function defs.rettypeopt(pos, x)
    if not x then
        -- When possible, we should change this default to the empty list
        -- or infer the return type.
        return { ast.TypeNil(pos) }
    else
        return x
    end
end

function defs.typeopt(t, isopt)
    if not isopt or isopt == "" then
        return t
    else
        return ast.TypeOption(t.loc, t)
    end
end

function defs.opt(x)
    if x == "" then
        return false
    else
        return x
    end
end

function defs.listopt(x)
    if x == "" then
        return {}
    else
        return x
    end
end

function defs.boolopt(x)
    return x ~= ""
end

function defs.nil_exp(pos--[[, s ]])
    -- We can't call ast.ExpNil directly in the parser because we
    -- need to drop the string capture that comes in the second argument.
    return ast.ExpNil(pos)
end

function defs.number_exp(pos, n)
    if math.type(n) == "integer" then
        return ast.ExpInteger(pos, n)
    elseif math.type(n) == "float" then
        return ast.ExpFloat(pos, n)
    else
        error("impossible")
    end
end

function defs.name_exp(pos, name)
    return ast.ExpVar(pos, ast.VarName(pos, name))
end

function defs.adjust_exp(pos, exp)
    if exp._tag == "Ast.ExpCall" then
        return ast.ExpAdjust(pos, exp)
    else
        return exp
    end
end

function defs.ifstat(pos, exp, block, thens, elseopt)
    table.insert(thens, 1, ast.Then(pos, exp, block))
    return ast.StatIf(pos, thens, elseopt)
end

function defs.fold_binop_left(pos, matches)
    local lhs = matches[1]
    for i = 2, #matches, 2 do
        local op  = matches[i]
        local rhs = matches[i+1]
        lhs = ast.ExpBinop(pos, lhs, op, rhs)
    end
    return lhs
end

-- Should this go on a separate constant propagation pass?
function defs.binop_concat(pos, lhs, op, rhs)
    if op then
        if rhs._tag == "Ast.ExpConcat" then
            table.insert(rhs.exps, 1, lhs)
            return rhs
        elseif (lhs._tag == "Ast.ExpString" or
            lhs._tag == "Ast.ExpInteger" or
            lhs._tag == "Ast.ExpFloat") and
            (rhs._tag == "Ast.ExpString" or
            rhs._tag == "Ast.ExpInteger" or
            rhs._tag == "Ast.ExpFloat") then
            return ast.ExpString(pos, lhs.value .. rhs.value)
        else
            return ast.ExpConcat(pos, { lhs, rhs })
        end
    else
        return lhs
    end
end

function defs.binop_right(pos, lhs, op, rhs)
    if op then
        return ast.ExpBinop(pos, lhs, op, rhs)
    else
        return lhs
    end
end

function defs.fold_unops(pos, unops, exp)
    for i = #unops, 1, -1 do
        local op = unops[i]
        exp = ast.ExpUnop(pos, op, exp)
    end
    return exp
end

-- We represent the suffix of an expression by a function that receives the
-- base expression and returns a full expression including the suffix.

function defs.suffix_funccall(pos, args)
    return function(exp)
        return ast.ExpCall(pos, exp, ast.ArgsFunc(pos, args))
    end
end

function defs.suffix_methodcall(pos, name, args)
    return function(exp)
        return ast.ExpCall(pos, exp, ast.ArgsMethod(pos, name, args))
    end
end

function defs.suffix_bracket(pos, index)
    return function(exp)
        return ast.ExpVar(pos, ast.VarBracket(pos, exp, index))
    end
end

function defs.suffix_dot(pos, name)
    return function(exp)
        return ast.ExpVar(pos, ast.VarDot(pos, exp, name))
    end
end

function defs.fold_suffixes(exp, suffixes)
    for i = 1, #suffixes do
        local suf = suffixes[i]
        exp = suf(exp)
    end
    return exp
end

function defs.exp2var(exp)
    return exp.var
end

function defs.exp_is_var(_, pos, exp)
    if exp._tag == "Ast.ExpVar" then
        return pos, exp
    else
        return false
    end
end

function defs.exp_is_call(_, pos, exp)
    if exp._tag == "Ast.ExpCall" then
        return pos, exp
    else
        return false
    end
end

function defs.recorddecl(pos, name, fields)
    local params, initlist = {}, {}
    for _, field in ipairs(fields) do
        table.insert(params, ast.Decl(field.loc, field.name, field.type, false))
        table.insert(initlist, ast.Field(field.loc, field.name,
            ast.ExpVar(field.loc, ast.VarName(field.loc, field.name))))
    end
    local body = ast.StatBlock(pos, {
        ast.StatReturn(pos, {
            ast.ExpInitList(pos, initlist)
        })
    })
    return ast.TopLevelRecord(pos, name, fields),
           ast.TopLevelStatic(pos, name, "new", params, { ast.TypeName(pos, name) }, body)
end

function defs.typeddecl(pos, name, type)
    return ast.Decl(pos, name, type, false)
end

function defs.optiondecl(pos, name, type)
    if type then
        return ast.Decl(pos, name, ast.TypeOption(type.loc, type), false)
    else
        return ast.Decl(pos, name, false, true)
    end
end

function defs.inferreddecl(pos, name)
    return ast.Decl(pos, name, false, false)
end

local grammar = re.compile([[

    program         <-  SKIP*
                        {| ( method
                           / toplevelfunc
                           / toplevelvar
                           / toplevelrecord
                           / import
                           / foreign )* |} !.

    method          <- (P  FUNCTION NAME COLON NAME^NameMethod
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block END^EndFunc)         -> TopLevelMethod

    toplevelfunc    <- (P  localopt FUNCTION NAME^NameFunc
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block END^EndFunc)         -> TopLevelFunc

    toplevelvar     <- (P localopt decl ASSIGN^AssignVar
                           !(IMPORT / FOREIGN)
                           exp^ExpVarDec)                        -> TopLevelVar

    toplevelrecord  <- (P  RECORD NAME^NameRecord
                           recordfields^FieldRecord
                           END^EndRecord)                        -> recorddecl

    localopt        <- (LOCAL)?                                  -> boolopt

    import          <- (P  LOCAL NAME^NameImport ASSIGN^AssignImport
                          !FOREIGN IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                          STRINGLIT^StringImport))               -> TopLevelImport

    foreign         <- (P  LOCAL NAME^NameImport ASSIGN^AssignImport
                           FOREIGN IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                           STRINGLIT^StringImport))              -> TopLevelForeignImport

    rettypeopt      <- (P  (COLON rettype^TypeFunc)?)            -> rettypeopt

    paramlist       <- {| (param (COMMA param^DeclParList)*)? |} -- produces {Decl}

    param           <- (P  NAME COLON^ParamSemicolon
                           type^TypeDecl)                        -> typeddecl

    decl            <- (P  NAME COLON type^TypeDecl)             -> typeddecl
                     / (P  NAME OPT COLON type^TypeDecl)         -> optiondecl
                     / (P  NAME OPT)                             -> optiondecl
                     / (P  NAME)                                 -> inferreddecl

    decllist        <- {| decl (COMMA decl^DeclParList)* |}      -- produces {Decl}

    simpletype      <- (((P  NIL)                                -> TypeNil
                     / (P  BOOLEAN)                              -> TypeBoolean
                     / (P  INTEGER)                              -> TypeInteger
                     / (P  FLOAT)                                -> TypeFloat
                     / (P  STRING)                               -> TypeString
                     / (P  VALUE)                                -> TypeValue
                     / (P  NAME DOT NAME^QualName)               -> TypeQualName
                     / (P  NAME)                                 -> TypeName
                     / (P  LCURLY type^TypeType
                           COLON
                           type^TypeType
                           RCURLY^RCurlyType)                    -> TypeMap
                     / (P  LCURLY type^TypeType
                           RCURLY^RCurlyType)                    -> TypeArray)
                                                  (OPT -> '?')?) -> typeopt

    typelist        <- ( LPAREN
                         {| (type (COMMA type^TypelistType)*)? |}
                         RPAREN^RParenTypelist )                 -- produces {Type}

    rettype         <- {| (P  typelist RARROW
                            rettype^TypeReturnTypes)             -> TypeFunction |}
                     / {| (P  {| simpletype |} RARROW
                             rettype^TypeReturnTypes)            -> TypeFunction |}
                     / typelist
                     / {| simpletype |}

    type            <- (P  typelist RARROW
                           rettype^TypeReturnTypes)              -> TypeFunction
                     / (P  {| simpletype |} RARROW
                           rettype^TypeReturnTypes)              -> TypeFunction
                     / simpletype

    recordfields    <- {| recordfield* |}                        -- produces {Decl}

    recordfield     <- (P  NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> typeddecl

    block           <- (P  {| statement* returnstat? |})         -> StatBlock

    statement       <- (SEMICOLON)                               -- ignore
                     / (DO block END^EndBlock)                   -- produces StatBlock
                     / (P  WHILE exp^ExpWhile DO^DoWhile
                                 block END^EndWhile)             -> StatWhile
                     / (P  REPEAT block UNTIL^UntilRepeat
                                      exp^ExpRepeat)             -> StatRepeat
                     / (P  IF exp^ExpIf THEN^ThenIf block
                           elseifstats elseopt END^EndIf)        -> ifstat
                     / (P  FOR decl^DeclFor
                           ASSIGN^AssignFor exp^Exp1For
                           COMMA^CommaFor exp^Exp2For
                           (COMMA exp^Exp3For)?                  -> opt
                           DO^DoFor block END^EndFor)            -> StatFor
                     / (P  LOCAL decllist^DeclLocal ASSIGN^AssignLocal
                                 explist^ExpLocal)                   -> StatDecl
                     / (P  varlist ASSIGN^AssignAssign
                               explist^ExpAssign)                    -> StatAssign
                     / &(exp ASSIGN) %{ExpAssign}
                     / (P  (suffixedexp => exp_is_call))         -> StatCall
                     / &exp %{ExpStat}

    elseifstats     <- {| elseifstat* |}                         -- produces {Then}

    elseifstat      <- (P  ELSEIF exp^ExpElseIf
                           THEN^ThenElseIf block)                -> Then

    elseopt         <- (ELSE block)?                             -> opt

    returnstat      <- (P  RETURN (explist? -> listopt) SEMICOLON?)      -> StatReturn

    op1             <- ( OR -> 'or' )
    op2             <- ( AND -> 'and' )
    op3             <- ( EQ -> '==' / NE -> '~=' / LT -> '<' /
                         GT -> '>'  / LE -> '<=' / GE -> '>=' )
    op4             <- ( BOR -> '|' )
    op5             <- ( BXOR -> '~' )
    op6             <- ( BAND -> '&' )
    op7             <- ( SHL -> '<<' / SHR -> '>>' )
    op8             <- ( CONCAT -> '..' )
    op9             <- ( ADD -> '+' / SUB -> '-' )
    op10            <- ( MUL -> '*' / MOD -> '%%' / DIV -> '/' / IDIV -> '//' )
    unop            <- ( NOT -> 'not' / LEN -> '#' / NEG -> '-' / BNEG -> '~' )
    op12            <- ( POW -> '^' )

    exp             <- e1
    e1              <- (P  {| e2  (op1  e2^OpExp)* |})           -> fold_binop_left
    e2              <- (P  {| e3  (op2  e3^OpExp)* |})           -> fold_binop_left
    e3              <- (P  {| e4  (op3  e4^OpExp)* |})           -> fold_binop_left
    e4              <- (P  {| e5  (op4  e5^OpExp)* |})           -> fold_binop_left
    e5              <- (P  {| e6  (op5  e6^OpExp)* |})           -> fold_binop_left
    e6              <- (P  {| e7  (op6  e7^OpExp)* |})           -> fold_binop_left
    e7              <- (P  {| e8  (op7  e8^OpExp)* |})           -> fold_binop_left
    e8              <- (P     e9  (op8  e8^OpExp)?)              -> binop_concat
    e9              <- (P  {| e10 (op9  e10^OpExp)* |})          -> fold_binop_left
    e10             <- (P  {| e11 (op10 e11^OpExp)* |})          -> fold_binop_left
    e11             <- (P  {| unop* |}  e12)                     -> fold_unops
    e12             <- (P  castexp (op12 e11^OpExp)?)            -> binop_right

    suffixedexp     <- (prefixexp {| expsuffix+ |})              -> fold_suffixes

    expsuffix       <- (P  funcargs)                             -> suffix_funccall
                     / (P  COLON NAME^NameColonExpSuf
                                 funcargs^FuncArgsExpSuf)        -> suffix_methodcall
                     / (P  LBRACKET exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf)         -> suffix_bracket
                     / (P  DOT NAME^NameDotExpSuf)               -> suffix_dot

    prefixexp       <- (P  NAME)                                 -> name_exp
                     / (P  LPAREN exp^ExpSimpleExp
                               RPAREN^RParSimpleExp)             -> adjust_exp


    castexp         <- (P  simpleexp AS type^CastMissingType)    -> ExpCast
                     / simpleexp                                 -- produces Exp

    simpleexp       <- (P  NIL)                                  -> nil_exp
                     / (P  FALSE -> tofalse)                     -> ExpBool
                     / (P  TRUE -> totrue)                       -> ExpBool
                     / (P  NUMBER)                               -> number_exp
                     / (P  STRINGLIT)                            -> ExpString
                     / initlist                                  -- produces Exp
                     / suffixedexp                               -- produces Exp
                     / prefixexp                                 -- produces Exp

    var             <- (suffixedexp => exp_is_var)               -> exp2var
                     / (P  NAME !expsuffix)                      -> name_exp -> exp2var

    varlist         <- {| var (COMMA var^ExpVarList)* |}            -- produces {Var}

    funcargs        <- (LPAREN (explist? -> listopt) RPAREN^RParFuncArgs)      -- produces {Exp}
                     / {| initlist |}                            -- produces {Exp}
                     / {| (P  STRINGLIT) -> ExpString |}         -- produces {Exp}

    explist         <- {| exp (COMMA exp^ExpExpList)* |}      -- produces {Exp}

    initlist        <- (P  LCURLY {| fieldlist? |}
                                  RCURLY^RCurlyInitList)         -> ExpInitList

    fieldlist       <- (field
                        (fieldsep
                         (field /
                          !RCURLY %{ExpFieldList}))*
                        fieldsep?)                          -- produces Field...

    field           <- (P  (key ASSIGN)? -> opt exp)       -> Field

    key             <- NAME
                     / LBRACKET exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf

    fieldsep        <- SEMICOLON / COMMA

    --
    -- Get current position
    --

    P <- {} => get_loc

    -- Create new rules for all our tokens, for the whitespace-skipping magic
    -- Currently done by hand but this is something that parser-gen should be
    -- able to do for us.

    SKIP            <- (%SPACE / %COMMENT)

    AND             <- %AND SKIP*
    BREAK           <- %BREAK SKIP*
    DO              <- %DO SKIP*
    ELSE            <- %ELSE SKIP*
    ELSEIF          <- %ELSEIF SKIP*
    END             <- %END SKIP*
    FALSE           <- %FALSE SKIP*
    FOR             <- %FOR SKIP*
    FUNCTION        <- %FUNCTION SKIP*
    GOTO            <- %GOTO SKIP*
    IF              <- %IF SKIP*
    IN              <- %IN SKIP*
    LOCAL           <- %LOCAL SKIP*
    NIL             <- %NIL SKIP*
    NOT             <- %NOT SKIP*
    OR              <- %OR SKIP*
    RECORD          <- %RECORD SKIP*
    REPEAT          <- %REPEAT SKIP*
    RETURN          <- %RETURN SKIP*
    THEN            <- %THEN SKIP*
    TRUE            <- %TRUE SKIP*
    UNTIL           <- %UNTIL SKIP*
    WHILE           <- %WHILE SKIP*
    IMPORT          <- %IMPORT SKIP*
    AS              <- %AS SKIP*
    FOREIGN         <- %FOREIGN SKIP*

    BOOLEAN         <- %BOOLEAN SKIP*
    INTEGER         <- %INTEGER SKIP*
    FLOAT           <- %FLOAT SKIP*
    STRING          <- %STRING SKIP*
    VALUE           <- %VALUE SKIP*

    ADD             <- %ADD SKIP*
    SUB             <- %SUB SKIP*
    MUL             <- %MUL SKIP*
    MOD             <- %MOD SKIP*
    DIV             <- %DIV SKIP*
    IDIV            <- %IDIV SKIP*
    POW             <- %POW SKIP*
    LEN             <- %LEN SKIP*
    BAND            <- %BAND SKIP*
    BXOR            <- %BXOR SKIP*
    BOR             <- %BOR SKIP*
    SHL             <- %SHL SKIP*
    SHR             <- %SHR SKIP*
    CONCAT          <- %CONCAT SKIP*
    EQ              <- %EQ SKIP*
    LT              <- %LT SKIP*
    GT              <- %GT SKIP*
    NE              <- %NE SKIP*
    LE              <- %LE SKIP*
    GE              <- %GE SKIP*
    ASSIGN          <- %ASSIGN SKIP*
    LPAREN          <- %LPAREN SKIP*
    RPAREN          <- %RPAREN SKIP*
    LBRACKET        <- %LBRACKET SKIP*
    RBRACKET        <- %RBRACKET SKIP*
    LCURLY          <- %LCURLY SKIP*
    RCURLY          <- %RCURLY SKIP*
    SEMICOLON       <- %SEMICOLON SKIP*
    COMMA           <- %COMMA SKIP*
    DOT             <- %DOT SKIP*
    DOTS            <- %DOTS SKIP*
    DBLCOLON        <- %DBLCOLON SKIP*
    COLON           <- %COLON SKIP*
    RARROW          <- %RARROW SKIP*
    OPT             <- %OPT SKIP*

    NUMBER          <- %NUMBER SKIP*
    STRINGLIT       <- %STRINGLIT SKIP*
    NAME            <- %NAME SKIP*

    -- Synonyms

    NEG             <- SUB
    BNEG            <- BXOR

]], defs)

function parser.parse(filename, input)
    -- Abort if someone calls this non-reentrant parser recursively
    assert(type(filename) == "string")
    assert(THIS_FILENAME == nil)

    THIS_FILENAME = filename
    local ast, err, errpos = grammar:match(input)
    THIS_FILENAME = nil

    if ast then
        return ast
    else
        local loc = location.from_pos(filename, input, errpos)
        return false, { label = err, loc = loc }
    end
end

function parser.error_to_string(err)
    local errmsg = syntax_errors.errors[err.label]
    return location.format_error(err.loc, "syntax error: %s", errmsg)
end

function parser.pretty_print_ast(ast)
    return inspect(ast, {
        process = function(item, path)
            if path[#path] ~= inspect.METATABLE then
                return item
            end
        end
    })
end

return parser
