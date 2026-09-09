--!nocheck
export type function ErasedTypeFunction_219(value)
    return value
end

export type ErasedResult_481<T = number, E... = (string)> = {
    ok: boolean,
    value: T?,
    errors: {E},
}
type ErasedCallback_927<T, A...> = (value: T, A...) -> (T, A...)
type ErasedOverload_315 = ((number) -> number) & ((string) -> string)
type ErasedQualified_624 = Shared.Entry<string>
type ErasedTagged_808 = "ready" | "waiting" | false
type ErasedAccess_394 = {
    read current: number,
    write next: number,
    read: string,
}

local origin = {x=2,y=3}
type ErasedOrigin_746 = typeof(origin)

local function identity<T, A...>(value: T, ...: A...): (T, A...)
    return value, ...
end

local mapper: <T>(T) -> T = function<T>(value: T): T
    return value
end

local maybe: number? = nil
local list: {number} = {2,4,6}
local dict: {[string]: number} = {alpha=5}
local shape: {x:number,y:number} = origin :: ErasedOrigin_746
local tight: ErasedResult_481<number> = {ok=true,value=1,errors={}}
local first, second = identity(8, "extra") :: number
local explicit = identity<<number, string>>(9, "typed")
local total=0

for index: number=1,#list do
    total+=list[index]
end
for key: string,value: number in dict do
    total+=value+#key
end

local function count(...: string): number
    return select("#",...)
end

print("TYPED_CORPUS_OK",mapper(total),shape.x,first,second==nil,explicit,count("a","b"),maybe==nil,tight.value)
