--!native
--!optimize 2

local band = bit32.band
local bor  = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local floor = math.floor

local BitBuffer = {}
BitBuffer.__index = BitBuffer

local TYPE_NIL = 0
local TYPE_BOOL = 1
local TYPE_INT = 2
local TYPE_FLOAT = 3
local TYPE_STRING = 4
local TYPE_TABLE = 5

function zigzagEncode(n)
	return bxor(lshift(n, 1), rshift(n, 31))
end

function zigzagDecode(n)
	return bxor(rshift(n, 1), -band(n, 1))
end

function BitBuffer.new(size)
	local self = setmetatable({}, BitBuffer)
	self.data = table.create(size or 64)
	self.writePos = 0
	self.readPos = 0
	return self
end

function BitBuffer:_ensure(index)
	local data = self.data
	if index > #data then
		for i = #data + 1, index do
			data[i] = 0
		end
	end
end

function BitBuffer:writeBits(value, bits)
	local bitPos = self.writePos
	local index = floor(bitPos / 32) + 1
	local offset = bitPos % 32

	self:_ensure(index + 1)

	value = band(value, lshift(1, bits) - 1)

	local current = self.data[index] or 0
	current = bor(current, lshift(value, offset))
	self.data[index] = current

	local overflow = offset + bits - 32
	if overflow > 0 then
		self.data[index + 1] = rshift(value, bits - overflow)
	end

	self.writePos = bitPos + bits
end

function BitBuffer:readBits(bits)
	local bitPos = self.readPos
	local index = floor(bitPos / 32) + 1
	local offset = bitPos % 32

	local value = rshift(self.data[index] or 0, offset)

	local overflow = offset + bits - 32
	if overflow > 0 then
		local nextVal = self.data[index + 1] or 0
		value = bor(value, lshift(nextVal, bits - overflow))
	end

	value = band(value, lshift(1, bits) - 1)
	self.readPos = bitPos + bits

	return value
end

function BitBuffer:reset()
	self.readPos = 0
end

function BitBuffer:writeVarInt(n)
	while n >= 0x80 do
		self:writeBits(bor(band(n, 0x7F), 0x80), 8)
		n = rshift(n, 7)
	end
	self:writeBits(n, 8)
end

function BitBuffer:readVarInt()
	local shift = 0
	local result = 0

	while true do
		local byte = self:readBits(8)
		result = bor(result, lshift(band(byte, 0x7F), shift))

		if band(byte, 0x80) == 0 then
			break
		end

		shift += 7
	end

	return result
end

function BitBuffer:writeBool(b)
	self:writeBits(b and 1 or 0, 1)
end

function BitBuffer:readBool()
	return self:readBits(1) == 1
end

function BitBuffer:writeInt(n)
	self:writeVarInt(zigzagEncode(n))
end

function BitBuffer:readInt()
	return zigzagDecode(self:readVarInt())
end

function BitBuffer:writeFloat(n)
	self:writeStringRaw(string.pack("d", n))
end

function BitBuffer:readFloat()
	return string.unpack("d", self:readStringRaw())
end

function BitBuffer:writeStringRaw(str)
	local len = #str
	self:writeVarInt(len)

	for i = 1, len do
		self:writeBits(str:byte(i), 8)
	end
end

function BitBuffer:readStringRaw()
	local len = self:readVarInt()
	local chars = table.create(len)

	for i = 1, len do
		chars[i] = string.char(self:readBits(8))
	end

	return table.concat(chars)
end

local function isArray(tbl)
	local n = #tbl
	for k in pairs(tbl) do
		if type(k) ~= "number" or k < 1 or k > n then
			return false
		end
	end
	return true
end

function BitBuffer:writeTable(tbl)
	local arrayMode = isArray(tbl)
	self:writeBool(arrayMode)

	if arrayMode then
		local len = #tbl
		self:writeVarInt(len)

		for i = 1, len do
			self:writeValue(tbl[i])
		end
	else
		local count = 0
		for _ in pairs(tbl) do count += 1 end

		self:writeVarInt(count)

		for k, v in pairs(tbl) do
			self:writeValue(k)
			self:writeValue(v)
		end
	end
end

function BitBuffer:readTable()
	local arrayMode = self:readBool()

	if arrayMode then
		local len = self:readVarInt()
		local tbl = table.create(len)

		for i = 1, len do
			tbl[i] = self:readValue()
		end

		return tbl
	else
		local count = self:readVarInt()
		local tbl = {}

		for _ = 1, count do
			local k = self:readValue()
			local v = self:readValue()
			tbl[k] = v
		end

		return tbl
	end
end

function BitBuffer:writeValue(value)
	local t = type(value)

	if value == nil then
		self:writeBits(TYPE_NIL, 3)

	elseif t == "boolean" then
		self:writeBits(TYPE_BOOL, 3)
		self:writeBool(value)

	elseif t == "number" then
		if floor(value) == value then
			self:writeBits(TYPE_INT, 3)
			self:writeInt(value)
		else
			self:writeBits(TYPE_FLOAT, 3)
			self:writeFloat(value)
		end

	elseif t == "string" then
		self:writeBits(TYPE_STRING, 3)
		self:writeStringRaw(value)

	elseif t == "table" then
		self:writeBits(TYPE_TABLE, 3)
		self:writeTable(value)

	else
		error("Unsupported type: " .. t)
	end
end

function BitBuffer:readValue()
	local typeTag = self:readBits(3)

	if typeTag == TYPE_NIL then
		return nil

	elseif typeTag == TYPE_BOOL then
		return self:readBool()

	elseif typeTag == TYPE_INT then
		return self:readInt()

	elseif typeTag == TYPE_FLOAT then
		return self:readFloat()

	elseif typeTag == TYPE_STRING then
		return self:readStringRaw()

	elseif typeTag == TYPE_TABLE then
		return self:readTable()

	else
		error("Unknown type tag: " .. tostring(typeTag))
	end
end

function BitBuffer:write(...)
	local n = select("#", ...)
	self:writeVarInt(n)

	for i = 1, n do
		self:writeValue(select(i, ...))
	end
end

function BitBuffer:read()
	local n = self:readVarInt()

	if n == 1 then
		return self:readValue()
	end

	local values = table.create(n)

	for i = 1, n do
		values[i] = self:readValue()
	end

	return table.unpack(values, 1, n)
end

function BitBuffer:getData()
	return self.data, self.writePos
end

function BitBuffer:setData(data, bitLength)
	self.data = data
	self.readPos = 0
	self.writePos = bitLength or (#data * 32)
end

function BitBuffer:byteLen()
	return math.ceil(self.writePos/8)
end

return BitBuffer
