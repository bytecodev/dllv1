-- Numeric bytecode compiler. Source AST nodes never become runtime handlers.
-- Each prototype owns a flat, encrypted four-word instruction stream.
local Parser = require("prometheus.parser")
local Runtime = require("prometheus.compiler.bytecode_runtime")
local C = {}
C.__index = C

local binary = {
    AddExpression = "ADD", SubExpression = "SUB", MulExpression = "MUL",
    DivExpression = "DIV", ModExpression = "MOD", PowExpression = "POW",
    StrCatExpression = "CONCAT", LessThanExpression = "LT", GreaterThanExpression = "GT",
    LessThanOrEqualsExpression = "LE", GreaterThanOrEqualsExpression = "GE",
    EqualsExpression = "EQ", NotEqualsExpression = "NE",
}
local unary = { NotExpression = "NOT", NegateExpression = "NEG", LenExpression = "LEN" }

function C:new(luaVersion, options)
    return setmetatable({
        protos = {}, constants = {}, constantIds = {string={},number={},boolean={}},
        slots = {}, nextSlot = 0, luaVersion = luaVersion or "LuaU",
        options = options or {},
    }, self)
end

function C:slot(scope, id)
    self.slots[scope] = self.slots[scope] or {}
    if not self.slots[scope][id] then
        self.nextSlot = self.nextSlot + 1
        self.slots[scope][id] = self.nextSlot
    end
    return self.slots[scope][id]
end

function C:temp()
    self.nextSlot = self.nextSlot + 1
    self.p.owned[self.nextSlot] = true
    return self.nextSlot
end

function C:constant(value)
    -- Deduplicate at build time only. Runtime still decrypts on demand, without
    -- retaining plaintext. Keep NaN and signed zero semantics out of table keys.
    local kind=type(value)
    if kind=="nil" and self.nilConstant then return self.nilConstant end
    local ids=self.constantIds[kind]
    local key=value
    if kind=="number" and value==0 and 1/value<0 then key="negative-zero" end
    if ids and value==value and ids[key] then return ids[key] end
    local id = #self.constants + 1
    self.constants[id] = {value = value}
    if kind=="nil" then self.nilConstant=id
    elseif ids and value==value then ids[key]=id end
    return id
end

function C:emit(op, a, b, c)
    local code = self.p.code
    code[#code + 1] = {op, a or 0, b or 0, c or 0}
    return #code
end
function C:pc() return #self.p.code + 1 end
function C:patch(at, target) self.p.code[at][2] = target or self:pc() end

function C:localSlot(scope, id, declare)
    local slot = self:slot(scope, id)
    self.p.refs[slot] = true
    if declare then self.p.owned[slot] = true end
    return slot
end

function C:variable(scope, id, ref)
    if scope.isGlobal then
        self:emit(ref and "GREF" or "GLOBAL", self:constant(scope:getVariableName(id)))
    else
        self:emit(ref and "REF" or "GET", self:localSlot(scope, id))
    end
end

function C:list(nodes)
    for i, node in ipairs(nodes) do self:expr(node, i == #nodes) end
    self:emit("PACK", #nodes)
end

local function fixedArgumentCount(args)
    local count=#args
    if count>3 then return nil end
    local last=args[count]
    if not last or last.isParenthesizedExpression then return count end
    if last.kind=="VarargExpression" or last.kind=="FunctionCallExpression" or
        last.kind=="PassSelfFunctionCallExpression" then return nil end
    return count
end

function C:call(n, tail, returnMode)
    local fixedCount=not tail and returnMode~=nil and fixedArgumentCount(n.args) or nil
    if fixedCount then
        if n.kind == "PassSelfFunctionCallExpression" or n.kind == "PassSelfFunctionCallStatement" then
            self:expr(n.base)
            for _,arg in ipairs(n.args) do self:expr(arg) end
            self:emit(returnMode==0 and "MCALL0" or "MCALL1", self:constant(n.passSelfFunctionName), fixedCount)
        elseif n.base.kind=="VariableExpression" and n.base.scope.isGlobal then
            for _,arg in ipairs(n.args) do self:expr(arg) end
            self:emit(returnMode==0 and "GCALL0" or "GCALL1",
                self:constant(n.base.scope:getVariableName(n.base.id)), fixedCount)
        else
            self:expr(n.base)
            for _,arg in ipairs(n.args) do self:expr(arg) end
            self:emit(returnMode==0 and "FCALL0" or "FCALL1", fixedCount)
        end
        return
    end
    self:expr(n.base)
    if n.kind == "PassSelfFunctionCallExpression" or n.kind == "PassSelfFunctionCallStatement" then
        self:emit("METHOD", self:constant(n.passSelfFunctionName))
        self:list(n.args)
        self:emit(tail and "TAILSELF" or returnMode == 0 and "SELF0" or returnMode == 1 and "SELF1" or "SELFCALL")
    else
        self:list(n.args)
        self:emit(tail and "TAILCALL" or returnMode == 0 and "CALL0" or returnMode == 1 and "CALL1" or "CALL")
    end
end

function C:expr(n, wantMulti)
    local k = n.kind
    if k == "NilExpression" or k == "BooleanExpression" or k == "NumberExpression" or k == "StringExpression" then
        self:emit("CONST", self:constant(n.value))
    elseif k == "VariableExpression" then self:variable(n.scope, n.id)
    elseif k == "VarargExpression" then self:emit("VARARG")
    elseif binary[k] then
        self:expr(n.lhs); self:expr(n.rhs); self:emit(binary[k])
    elseif unary[k] then
        self:expr(n.rhs); self:emit(unary[k])
    elseif k == "OrExpression" or k == "AndExpression" then
        self:expr(n.lhs); self:emit("SINGLE"); self:emit("DUP")
        local branch = self:emit(k == "OrExpression" and "JTRUE" or "JFALSE")
        self:emit("DROP"); self:expr(n.rhs); self:emit("SINGLE"); self:patch(branch)
    elseif k == "IndexExpression" then
        self:expr(n.base); self:expr(n.index); self:emit("INDEX")
    elseif k == "FunctionCallExpression" or k == "FunctionCallStatement" then
        local returnMode=1
        if wantMulti and not n.isParenthesizedExpression then returnMode=nil end
        self:call(n, false, returnMode)
    elseif k == "PassSelfFunctionCallExpression" or k == "PassSelfFunctionCallStatement" then
        local returnMode=1
        if wantMulti and not n.isParenthesizedExpression then returnMode=nil end
        self:call(n, false, returnMode)
    elseif k == "FunctionLiteralExpression" then
        self:emit("CLOSURE", self:prototype(n.args, n.body))
    elseif k == "TableConstructorExpression" then
        self:emit("TABLE")
        local index = 1
        for i, entry in ipairs(n.entries) do
            if entry.kind == "KeyedTableEntry" then
                self:expr(entry.key); self:expr(entry.value); self:emit("FIELD")
            else
                self:expr(entry.value, i == #n.entries); self:emit("APPEND", index, i == #n.entries and 1 or 0)
                index = index + 1
            end
        end
    elseif k == "IfElseExpression" then
        local ends = {}
        local function arm(condition, value)
            self:expr(condition)
            local skip = self:emit("JFALSE")
            self:expr(value); self:emit("SINGLE")
            ends[#ends + 1] = self:emit("JUMP"); self:patch(skip)
        end
        arm(n.condition, n.true_value)
        for _, e in ipairs(n.elseifs) do arm(e.condition, e.value) end
        self:expr(n.false_value); self:emit("SINGLE")
        for _, at in ipairs(ends) do self:patch(at) end
    else error("Numeric VM: unsupported expression " .. tostring(k)) end
    if n.isParenthesizedExpression then self:emit("SINGLE") end
end

function C:reference(n)
    if n.kind == "AssignmentVariable" or n.kind == "VariableExpression" then
        self:variable(n.scope, n.id, true)
    elseif n.kind == "AssignmentIndexing" or n.kind == "IndexExpression" then
        self:expr(n.base); self:expr(n.index); self:emit("INDEXREF")
    else error("Numeric VM: unsupported assignment " .. n.kind) end
end

function C:block(body)
    for _, n in ipairs(body.statements) do self:statement(n) end
end

function C:loop(n, body)
    local previous = self.p.loop
    local loop = {breaks = {}, continues = {}}
    self.p.loop = loop
    body(loop)
    for _, at in ipairs(loop.breaks) do self:patch(at) end
    self.p.loop = previous
end

function C:statement(n)
    local k = n.kind
    if k == "NopStatement" then return
    elseif k == "LocalVariableDeclaration" then
        self:list(n.expressions)
        for i, id in ipairs(n.ids) do self:emit("NEW", self:localSlot(n.scope, id, true), i) end
        self:emit("DROP")
    elseif k == "AssignmentStatement" then
        for _, lhs in ipairs(n.lhs) do self:reference(lhs) end
        self:list(n.rhs); self:emit("ASSIGN", #n.lhs)
    elseif k:match("^Compound") then
        local ops = {CompoundAddStatement="ADD", CompoundSubStatement="SUB", CompoundMulStatement="MUL",
            CompoundDivStatement="DIV", CompoundModStatement="MOD", CompoundPowStatement="POW", CompoundConcatStatement="CONCAT"}
        assert(ops[k], "Numeric VM: unsupported compound " .. k)
        self:reference(n.lhs); self:emit("DUP"); self:emit("DEREF")
        self:expr(n.rhs); self:emit(ops[k]); self:emit("ASSIGN", 1)
    elseif k == "FunctionCallStatement" or k == "PassSelfFunctionCallStatement" then
        self:call(n, false, 0)
    elseif k == "ReturnStatement" then
        local value=n.args[1]
        if #n.args==1 and not value.isParenthesizedExpression and
            (value.kind=="FunctionCallExpression" or value.kind=="PassSelfFunctionCallExpression") then
            self:call(value,true)
        else self:list(n.args); self:emit("RETURN") end
    elseif k == "DoStatement" then self:block(n.body)
    elseif k == "LocalFunctionDeclaration" then
        local slot = self:localSlot(n.scope, n.id, true)
        self:emit("PACK", 0); self:emit("NEW", slot, 1); self:emit("DROP")
        self:emit("REF", slot); self:emit("CLOSURE", self:prototype(n.args, n.body)); self:emit("ASSIGN", 1)
    elseif k == "FunctionDeclaration" then
        if #n.indices == 0 then self:variable(n.scope, n.id, true)
        else
            self:variable(n.scope, n.id)
            for i, name in ipairs(n.indices) do
                self:emit("CONST", self:constant(name))
                self:emit(i == #n.indices and "INDEXREF" or "INDEX")
            end
        end
        self:emit("CLOSURE", self:prototype(n.args, n.body)); self:emit("ASSIGN", 1)
    elseif k == "IfStatement" then
        local ends = {}
        local function arm(condition, body)
            self:expr(condition); local skip = self:emit("JFALSE")
            self:block(body); ends[#ends + 1] = self:emit("JUMP"); self:patch(skip)
        end
        arm(n.condition, n.body)
        for _, e in ipairs(n.elseifs) do arm(e.condition, e.body) end
        if n.elsebody then self:block(n.elsebody) end
        for _, at in ipairs(ends) do self:patch(at) end
    elseif k == "BreakStatement" or k == "ContinueStatement" then
        assert(self.p.loop, "Numeric VM: loop control outside loop")
        local list = k == "BreakStatement" and self.p.loop.breaks or self.p.loop.continues
        list[#list + 1] = self:emit("JUMP")
    elseif k == "WhileStatement" then
        self:loop(n, function(loop)
            local start = self:pc()
            self:expr(n.condition); local done = self:emit("JFALSE")
            self:block(n.body)
            for _, at in ipairs(loop.continues) do self:patch(at, start) end
            self:emit("JUMP", start); self:patch(done)
        end)
    elseif k == "RepeatStatement" then
        self:loop(n, function(loop)
            local start = self:pc(); self:block(n.body)
            for _, at in ipairs(loop.continues) do self:patch(at) end
            self:expr(n.condition); self:emit("JFALSE", start)
        end)
    elseif k == "ForStatement" then
        local idx, limit, step = self:temp(), self:temp(), self:temp()
        self:expr(n.initialValue); self:expr(n.finalValue)
        if n.incrementBy then self:expr(n.incrementBy) else self:emit("CONST", self:constant(1)) end
        self:emit("PACK", 3); self:emit("FORPREP", idx, limit, step)
        self:loop(n, function(loop)
            local start = self:pc(); self:emit("FORCHECK", idx, limit, step)
            local done = self:emit("JFALSE")
            self:emit("GET", idx); self:emit("NEW", self:localSlot(n.scope, n.id, true), 1); self:emit("DROP")
            self:block(n.body)
            for _, at in ipairs(loop.continues) do self:patch(at) end
            self:emit("FORSTEP", idx, step); self:emit("JUMP", start); self:patch(done)
        end)
    elseif k == "ForInStatement" then
        local iter, state, ctrl = self:temp(), self:temp(), self:temp()
        self:list(n.expressions); self:emit("ITERPREP", iter, state, ctrl)
        self:loop(n, function(loop)
            local start = self:pc(); self:emit("ITERNEXT", iter, state, ctrl)
            for i, id in ipairs(n.ids) do self:emit("NEW", self:localSlot(n.scope, id, true), i) end
            self:emit("DROP"); self:emit("GET", ctrl); self:emit("CONST", self:constant(nil)); self:emit("NE")
            local done = self:emit("JFALSE"); self:block(n.body)
            for _, at in ipairs(loop.continues) do self:patch(at, start) end
            self:emit("JUMP", start); self:patch(done)
        end)
    else error("Numeric VM: unsupported statement " .. tostring(k)) end
end

function C:prototype(args, body)
    local parent = self.p
    local p = {code = {}, params = {}, refs = {}, owned = {}, captures = {}}
    local id = #self.protos + 1; self.protos[id] = p; self.p = p
    for _, arg in ipairs(args) do
        if arg.kind ~= "VarargExpression" then
            p.params[#p.params + 1] = self:localSlot(arg.scope, arg.id, true)
        end
    end
    self:block(body); self:emit("PACK", 0); self:emit("RETURN")
    for slot in pairs(p.refs) do
        if not p.owned[slot] then
            p.captures[#p.captures + 1] = slot
            if parent then parent.refs[slot] = true end
        end
    end
    table.sort(p.captures)
    self.p = parent
    return id
end

function C:compile(ast)
    self:prototype({}, ast.body)
    local source = Runtime.emit(self.protos, self.constants, self.luaVersion, self.options)
    return Parser:new({LuaVersion = "Lua51"}):parse(source)
end

return C
