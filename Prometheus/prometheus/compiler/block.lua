-- This Script is Part of the Prometheus Obfuscator by levno-710
--
-- block.lua
--
-- Block management for the compiler

local Scope = require("prometheus.scope");
local util = require("prometheus.util");

local lookupify = util.lookupify;

return function(Compiler)
    function Compiler:createBlock()
        local id;
        local bucket;
        repeat
            bucket = math.random(0, 2^21);
            -- Keep generated block ids sparsely spaced. This makes threshold
            -- dispatch safer and prevents a dense, easy-to-sort id table.
            id = bucket * 8 + (self.blockIdSalt or 0);
        until not self.usedBlockIds[id] and not (self.usedBlockIdBuckets and self.usedBlockIdBuckets[bucket]);
        self.usedBlockIds[id] = true;
        if self.usedBlockIdBuckets then
            self.usedBlockIdBuckets[bucket] = true;
        end

        local scope = Scope:new(self.containerFuncScope);
        local block = {
            id = id;
            statements = {};
            scope = scope;
            advanceToNextBlock = true;
        };
        table.insert(self.blocks, block);
        return block;
    end

    function Compiler:setActiveBlock(block)
        self.activeBlock = block;
    end

    function Compiler:addStatement(statement, writes, reads, usesUpvals)
        if(self.activeBlock.advanceToNextBlock) then
            table.insert(self.activeBlock.statements, {
                statement = statement,
                writes = lookupify(writes),
                reads = lookupify(reads),
                usesUpvals = usesUpvals or false,
            });
        end
    end
end

