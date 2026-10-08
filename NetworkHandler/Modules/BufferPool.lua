--!native
--!optimize 2

local BitBuffer = require(script.Parent.BitBuffer)
local BufferPool = {}
BufferPool.__index = BufferPool

function BufferPool.new(initialSize: number?, maxRetained: number?)
    local size = initialSize or 64
    local limit = maxRetained or 128
    assert(typeof(size) == "number" and size > 0 and size % 1 == 0 and size < math.huge, "Invalid buffer size")
    assert(typeof(limit) == "number" and limit >= 0 and limit % 1 == 0 and limit < math.huge, "Invalid pool limit")
    return setmetatable({
        pool = {},
        initialSize = size,
        maxRetained = limit,
        _inPool = setmetatable({}, {__mode = "k"}),
    }, BufferPool)
end

function BufferPool:acquire()
    local buff = table.remove(self.pool)
    if buff then
        self._inPool[buff] = nil
        buff:reset()
        return buff
    end
    return BitBuffer.new(self.initialSize)
end

function BufferPool:release(buff)
    if not buff or typeof(buff) ~= "table" or typeof(buff.reset) ~= "function" then return false end
    if self._inPool[buff] then return false end
    if #self.pool >= self.maxRetained then return false end
    buff:reset()
    self._inPool[buff] = true
    self.pool[#self.pool + 1] = buff
    return true
end

return BufferPool
