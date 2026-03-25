--!native
--!optimize 2

local BufferUtil = require(script.Parent.BufferUtil)

local BitBuffer = {}
BitBuffer.__index = BitBuffer

function zigzagEncode(n: number): number
	return bit32.bxor(bit32.lshift(n, 1), bit32.rshift(n, 31))
end

function zigzagDecode(n: number): number
	return bit32.bxor(bit32.rshift(n, 1), -bit32.band(n, 1))
end

function BitBuffer.new(size: number?)
	local self = setmetatable({}, BitBuffer)
	self.buffer = BufferUtil.new(size or 64)
	self.writePos = 0
	self.readPos = 0
	return self
end

function BitBuffer:_ensure(byteIndex: number)
	local len = BufferUtil.len(self.buffer)
	if byteIndex > len then
		local newSize = math.max(byteIndex, len * 2)
		local newBuff = BufferUtil.new(newSize)
		BufferUtil.copy(newBuff, 0, self.buffer, 0, len)
		self.buffer = newBuff
	end
end

function BitBuffer:alignToByte()
	if self.writePos % 8 ~= 0 then
		self.writePos += (8 - (self.writePos % 8))
	end
end

function BitBuffer:alignReadToByte()
	if self.readPos % 8 ~= 0 then
		self.readPos += (8 - (self.readPos % 8))
	end
end

function BitBuffer:writeBits(value: number, bits: number)
	assert(bits <= 32)

	if bits == 8 and (self.writePos % 8 == 0) then
		local index = self.writePos // 8
		self:_ensure(index + 1)
		BufferUtil.write(self.buffer, "u8", index, bit32.band(value, 0xFF))
		self.writePos += 8
		return
	end

	local bitPos = self.writePos
	local index = bitPos // 8
	local offset = bitPos % 8

	self:_ensure(index + 4)

	value = bit32.band(value, bit32.lshift(1, bits) - 1)

	local remaining = bits
	local shift = 0

	while remaining > 0 do
		local byte = BufferUtil.read(self.buffer, "u8", index)

		local writeBits = math.min(8 - offset, remaining)
		local mask = bit32.lshift(bit32.lshift(1, writeBits) - 1, offset)

		byte = bit32.band(byte, bit32.bnot(mask))
		byte = bit32.bor(byte, bit32.lshift(bit32.extract(value, shift, writeBits), offset))

		BufferUtil.write(self.buffer, "u8", index, byte)

		remaining -= writeBits
		shift += writeBits
		index += 1
		offset = 0
	end

	self.writePos = bitPos + bits
end

function BitBuffer:readBits(bits: number): number
	assert(bits <= 32)

	if bits == 8 and (self.readPos % 8 == 0) then
		local index = self.readPos // 8
		self.readPos += 8
		return BufferUtil.read(self.buffer, "u8", index)
	end

	local bitPos = self.readPos
	local index = bitPos // 8
	local offset = bitPos % 8

	local result = 0
	local shift = 0
	local remaining = bits

	while remaining > 0 do
		local byte = BufferUtil.read(self.buffer, "u8", index)

		local readBits = math.min(8 - offset, remaining)
		local chunk = bit32.extract(byte, offset, readBits)

		result = bit32.bor(result, bit32.lshift(chunk, shift))

		remaining -= readBits
		shift += readBits
		index += 1
		offset = 0
	end

	self.readPos = bitPos + bits
	return result
end

function BitBuffer:writeBool(b: boolean)
	self:writeBits(b and 1 or 0, 1)
end

function BitBuffer:readBool(): boolean
	return self:readBits(1) == 1
end

function BitBuffer:writeVarInt(n: number)
	while n >= 0x80 do
		self:writeBits(bit32.bor(bit32.band(n, 0x7F), 0x80), 8)
		n = bit32.rshift(n, 7)
	end
	self:writeBits(n, 8)
end

function BitBuffer:readVarInt(): number
	local shift = 0
	local result = 0

	while true do
		local byte = self:readBits(8)
		result = bit32.bor(result, bit32.lshift(bit32.band(byte, 0x7F), shift))
		if bit32.band(byte, 0x80) == 0 then break end
		shift += 7
	end

	return result
end

function BitBuffer:writeInt(n: number)
	self:writeVarInt(zigzagEncode(n))
end

function BitBuffer:readInt(): number
	return zigzagDecode(self:readVarInt())
end

function BitBuffer:writeFloat(n: number)
	self:alignToByte()

	local index = self.writePos // 8
	self:_ensure(index + 8)

	BufferUtil.write(self.buffer, "f64", index, n)
	self.writePos += 64
end

function BitBuffer:readFloat(): number
	self:alignReadToByte()
	assert(self.readPos % 8 == 0, "Unaligned float read")

	local index = self.readPos // 8
	self.readPos += 64

	return BufferUtil.read(self.buffer, "f64", index)
end

function BitBuffer:writeStringRaw(str: string)
	self:alignToByte()

	local len = #str
	self:writeVarInt(len)

	local index = self.writePos // 8
	self:_ensure(index + len)

	for i = 1, len do
		BufferUtil.write(self.buffer, "u8", index + i - 1, str:byte(i))
	end

	self.writePos += len * 8
end

function BitBuffer:readStringRaw(): string
	self:alignReadToByte()
	local len = self:readVarInt()

	assert(self.readPos % 8 == 0, "Unaligned string read")
	local index = self.readPos // 8

	local chars = table.create(len)

	for i = 1, len do
		chars[i] = string.char(BufferUtil.read(self.buffer, "u8", index + i - 1))
	end

	self.readPos += len * 8
	return table.concat(chars)
end

local TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_TABLE, TYPE_VECTOR3 = 0,1,2,3,4,5,6
function isArray(tbl)
	local n = #tbl
	for k in pairs(tbl) do
		if type(k) ~= "number" or k < 1 or k > n then
			return false
		end
	end
	return true
end

function BitBuffer:writeValue(value, seen)
	seen = seen or {}
	local t = type(value)

	if value == nil then
		self:writeBits(TYPE_NIL, 3)

	elseif t == "boolean" then
		self:writeBits(TYPE_BOOL, 3)
		self:writeBool(value)

	elseif t == "number" then
		if math.floor(value) == value then
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
		self:writeTable(value, seen)
	elseif t == 'Vector3' then
		self:writeBits(TYPE_VECTOR3, 3)
		local x, y, z = math.floor(value.X * 100 + 0.001), math.floor(value.Y * 100 + 0.001), math.floor(value.Z * 100 + 0.001)
		self:writeInt(x)
		self:writeInt(y)
		self:writeInt(z)
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
	elseif typeTag == TYPE_VECTOR3 then
		local x, y, z = self:readInt(), self:readInt(), self:readInt()
		return Vector3.new(x/100, y/100, z/100)
	else
		error("Unknown type")
	end
end

function BitBuffer:writeTable(tbl, seen)
	seen = seen or {}
	if seen[tbl] then error("Circular table") end
	seen[tbl] = true

	local arrayMode = isArray(tbl)
	self:writeBool(arrayMode)

	if arrayMode then
		self:writeVarInt(#tbl)
		for i = 1, #tbl do
			self:writeValue(tbl[i], seen)
		end
	else
		local count = 0
		for _ in pairs(tbl) do count += 1 end
		self:writeVarInt(count)
		for k,v in pairs(tbl) do
			self:writeValue(k, seen)
			self:writeValue(v, seen)
		end
	end

	seen[tbl] = nil
end

function BitBuffer:readTable()
	local arrayMode = self:readBool()

	if arrayMode then
		local len = self:readVarInt()
		local t = table.create(len)
		for i = 1, len do
			t[i] = self:readValue()
		end
		return t
	else
		local count = self:readVarInt()
		local t = {}
		for _ = 1, count do
			t[self:readValue()] = self:readValue()
		end
		return t
	end
end

function BitBuffer:write(...: any)
	local n = select("#", ...)
	self:writeVarInt(n)
	for i = 1, n do
		self:writeValue(select(i, ...))
	end
end

function BitBuffer:read(): ...any
	local n = self:readVarInt()
	if n == 1 then return self:readValue() end

	local t = table.create(n)
	for i = 1, n do
		t[i] = self:readValue()
	end
	return table.unpack(t, 1, n)
end

function BitBuffer:getBuffer(): buffer
	return self.buffer
end

function BitBuffer:setBuffer(buff: buffer, bitLength: number?)
	self.buffer = buff
	self.readPos = 0
	self.writePos = bitLength or (BufferUtil.len(buff) * 8)
end

function BitBuffer:getByteLength(): number
	return math.ceil(self.writePos / 8)
end

function BitBuffer:reset()
	self.readPos = 0
end

return BitBuffer
