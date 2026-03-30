--!native
--!optimize 2

local BitBuffer = require(script.Parent.BitBuffer)
local BufferPool = {}
BufferPool.__index = BufferPool

function BufferPool.new(initialSize: number)
	local self = {
		pool = {},
		initialSize = initialSize or 64
	}
	return setmetatable(self, BufferPool)
end

function BufferPool:acquire()
	local buff = table.remove(self.pool)
	if buff then
		buff:reset()
		return buff
	end
	return BitBuffer.new(self.initialSize)
end

function BufferPool:release(buff)
	if not buff then return end
	buff:reset()
	table.insert(self.pool, buff)
end

return BufferPool
