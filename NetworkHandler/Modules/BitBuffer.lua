--!native
--!optimize 2

local BitBuffer = {}
BitBuffer.__index = BitBuffer

-- Zigzag encoding/decoding for 32-bit signed integers
function zigzagEncode(n: number): number
	return bit32.bxor(bit32.lshift(n, 1), bit32.rshift(n, 31))
end

function zigzagDecode(n: number): number
	return bit32.bxor(bit32.rshift(n, 1), -bit32.band(n, 1))
end

-- Helper to create zero-initialized array
function createArray(size: number): {number}
	local t: {number} = {}
	for i = 1, size do
		t[i] = 0
	end
	return t
end

function BitBuffer.new(size: number?)
	local self = setmetatable({}, BitBuffer)
	self.data = createArray(size or 64)
	self.writePos = 0
	self.readPos = 0
	return self
end

function BitBuffer:_ensure(index: number): ()
	if index > #self.data then
		for i = #self.data + 1, index do
			self.data[i] = 0
		end
	end
end

function BitBuffer:writeBits(value: number, bits: number): ()
	assert(bits <= 32, "Cannot write more than 32 bits at once")

	local bitPos = self.writePos
	local index = math.floor(bitPos / 32) + 1
	local offset = bitPos % 32

	self:_ensure(index + 1)

	value = bit32.band(value, bit32.lshift(1, bits) - 1)
	self.data[index] = bit32.bor(self.data[index] or 0, bit32.lshift(value, offset))

	local overflow = offset + bits - 32
	if overflow > 0 then
		self:_ensure(index + 1)
		self.data[index + 1] = bit32.bor(self.data[index + 1] or 0, bit32.rshift(value, bits - overflow))
	end

	self.writePos = bitPos + bits
end

function BitBuffer:readBits(bits: number): number
	assert(bits <= 32, "Cannot read more than 32 bits at once")

	local bitPos = self.readPos
	local index = math.floor(bitPos / 32) + 1
	local offset = bitPos % 32

	local value = bit32.rshift(self.data[index] or 0, offset)
	local overflow = offset + bits - 32

	if overflow > 0 then
		local nextVal = self.data[index + 1] or 0
		value = bit32.bor(value, bit32.lshift(nextVal, bits - overflow))
	end

	value = bit32.band(value, bit32.lshift(1, bits) - 1)
	self.readPos = bitPos + bits
	return value
end

function BitBuffer:reset(): ()
	self.readPos = 0
end

function BitBuffer:writeVarInt(n: number): ()
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
		if bit32.band(byte, 0x80) == 0 then
			break
		end
		shift += 7
	end

	return result
end

function BitBuffer:writeBool(b: boolean): ()
	self:writeBits(b and 1 or 0, 1)
end

function BitBuffer:readBool(): boolean
	return self:readBits(1) == 1
end

function BitBuffer:writeInt(n: number): ()
	self:writeVarInt(zigzagEncode(n))
end

function BitBuffer:readInt(): number
	return zigzagDecode(self:readVarInt())
end

function BitBuffer:writeFloat(n: number): ()
	local packed = string.pack("d", n)
	for i = 1, #packed do
		self:writeBits(packed:byte(i), 8)
	end
end

function BitBuffer:readFloat(): number
	local bytes: {number} = {}
	for i = 1, 8 do
		bytes[i] = self:readBits(8)
	end
	return string.unpack("d", string.char(table.unpack(bytes)))
end

function BitBuffer:writeStringRaw(str: string): ()
	self:writeVarInt(#str)
	for i = 1, #str do
		self:writeBits(str:byte(i), 8)
	end
end

function BitBuffer:readStringRaw(): string
	local len = self:readVarInt()
	local chars: {string} = {}
	for i = 1, len do
		chars[i] = string.char(self:readBits(8))
	end
	return table.concat(chars)
end

local function isArray(tbl: {any}): boolean
	local n = #tbl
	for k in pairs(tbl) do
		if type(k) ~= "number" or k < 1 or k > n then
			return false
		end
	end
	return true
end

function BitBuffer:writeTable(tbl: {any}, seen: {[{}]: boolean}? ): ()
	seen = seen or {}
	if seen[tbl] then
		error("Circular table detected")
	end
	seen[tbl] = true

	local TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_TABLE = 0, 1, 2, 3, 4, 5
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
		for k, v in pairs(tbl) do
			self:writeValue(k, seen)
			self:writeValue(v, seen)
		end
	end

	seen[tbl] = nil
end

function BitBuffer:readTable(): {any}
	local TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_TABLE = 0, 1, 2, 3, 4, 5
	local arrayMode = self:readBool()
	if arrayMode then
		local len = self:readVarInt()
		local tbl: {any} = {}
		for i = 1, len do
			tbl[i] = self:readValue()
		end
		return tbl
	else
		local count = self:readVarInt()
		local tbl: {any} = {}
		for _ = 1, count do
			local k = self:readValue()
			local v = self:readValue()
			tbl[k] = v
		end
		return tbl
	end
end

function BitBuffer:writeValue(value: any, seen: {[{}]: boolean}? ): ()
	local TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_TABLE = 0, 1, 2, 3, 4, 5
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
	else
		error("Unsupported type: " .. t)
	end
end

function BitBuffer:readValue(): any
	local TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_TABLE = 0, 1, 2, 3, 4, 5
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

function BitBuffer:write(...: any): ()
	local n = select("#", ...)
	self:writeVarInt(n)
	for i = 1, n do
		self:writeValue(select(i, ...))
	end
end

function BitBuffer:read(): ...any
	local n = self:readVarInt()
	if n == 1 then
		return self:readValue()
	end
	local values: {any} = {}
	for i = 1, n do
		values[i] = self:readValue()
	end
	return table.unpack(values, 1, n)
end

function BitBuffer:getData(): ({number}, number)
	return self.data, self.writePos
end

function BitBuffer:setData(data: {number}, bitLength: number?): ()
	self.data = data
	self.readPos = 0
	self.writePos = bitLength or (#data * 32)
end

function BitBuffer:byteLen(): number
	return math.ceil(self.writePos / 8)
end

return BitBuffer
