--!native
--!optimize 2

local BufferUtil = require(script.Parent.BufferUtil)

local BitBuffer = {}
BitBuffer.__index = BitBuffer

--// CONSTANTS
local MAX_VARINT_BITS = 35

local TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_TABLE, TYPE_VECTOR3 =
	0,1,2,3,4,5,6

--// ZIGZAG
function zigzagEncode(n: number): number
	return bit32.bxor(bit32.lshift(n, 1), bit32.rshift(n, 31))
end

function zigzagDecode(n: number): number
	return bit32.bxor(bit32.rshift(n, 1), -bit32.band(n, 1))
end

--// SAFE MASK
function mask(bits: number): number
	return (bits == 32) and 0xFFFFFFFF or (bit32.lshift(1, bits) - 1)
end

--// ARRAY CHECK (STRICT)
function isArray(tbl)
	local max, count = 0, 0
	for k in pairs(tbl) do
		if type(k) ~= "number" or k <= 0 or k % 1 ~= 0 then
			return false
		end
		if k > max then max = k end
		count += 1
	end
	return max == count
end

--// CONSTRUCTOR
function BitBuffer.new(size: number?)
	local self = setmetatable({}, BitBuffer)
	self.buffer = BufferUtil.new(size or 64)
	self.writePos = 0
	self.readPos = 0
	return self
end

--// ENSURE CAPACITY (EXACT)
function BitBuffer:_ensureBits(bitCount: number)
	local neededBytes = math.ceil(bitCount / 8)
	local len = BufferUtil.len(self.buffer)

	if neededBytes > len then
		local newSize = math.max(neededBytes, len * 2)
		local newBuff = BufferUtil.new(newSize)
		BufferUtil.copy(newBuff, 0, self.buffer, 0, len)
		self.buffer = newBuff
	end
end

--// ALIGN (SAFE ZERO FILL)
function BitBuffer:alignToByte()
	local mod = self.writePos % 8
	if mod ~= 0 then
		self:writeBits(0, 8 - mod)
	end
end

function BitBuffer:alignReadToByte()
	local mod = self.readPos % 8
	if mod ~= 0 then
		self.readPos += (8 - mod)
	end
end

--// WRITE BITS (FAST PATHS)
function BitBuffer:writeBits(value: number, bits: number)
	assert(bits > 0 and bits <= 32)

	local bitPos = self.writePos
	local aligned = (bitPos % 8 == 0)
	local index = bitPos // 8

	self:_ensureBits(bitPos + bits)

	value = bit32.band(value, mask(bits))

	--// FAST PATHS
	if aligned then
		if bits == 8 then
			BufferUtil.write(self.buffer, "u8", index, value)
			self.writePos += 8
			return
		elseif bits == 16 then
			BufferUtil.write(self.buffer, "u16", index, value)
			self.writePos += 16
			return
		elseif bits == 32 then
			BufferUtil.write(self.buffer, "u32", index, value)
			self.writePos += 32
			return
		end
	end

	--// SLOW PATH (BIT PACK)
	local offset = bitPos % 8
	local remaining = bits
	local shift = 0

	while remaining > 0 do
		local byte = BufferUtil.read(self.buffer, "u8", index) or 0

		local writeBits = math.min(8 - offset, remaining)
		local m = bit32.lshift(mask(writeBits), offset)

		byte = bit32.band(byte, bit32.bnot(m))
		byte = bit32.bor(byte, bit32.lshift(bit32.extract(value, shift, writeBits), offset))

		BufferUtil.write(self.buffer, "u8", index, byte)

		remaining -= writeBits
		shift += writeBits
		index += 1
		offset = 0
	end

	self.writePos = bitPos + bits
end

--// READ BITS (SAFE)
function BitBuffer:readBits(bits: number): number
	assert(bits > 0 and bits <= 32)
	assert(self.readPos + bits <= self.writePos, "Read overflow")

	local bitPos = self.readPos
	local aligned = (bitPos % 8 == 0)
	local index = bitPos // 8

	--// FAST PATHS
	if aligned then
		if bits == 8 then
			self.readPos += 8
			return BufferUtil.read(self.buffer, "u8", index)
		elseif bits == 16 then
			self.readPos += 16
			return BufferUtil.read(self.buffer, "u16", index)
		elseif bits == 32 then
			self.readPos += 32
			return BufferUtil.read(self.buffer, "u32", index)
		end
	end

	--// SLOW PATH
	local offset = bitPos % 8
	local result = 0
	local shift = 0
	local remaining = bits

	while remaining > 0 do
		local byte = BufferUtil.read(self.buffer, "u8", index) or 0

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

--// BASIC TYPES
function BitBuffer:writeBool(b: boolean)
	self:writeBits(b and 1 or 0, 1)
end

function BitBuffer:readBool(): boolean
	return self:readBits(1) == 1
end

--// VARINT (SAFE)
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

	while shift < MAX_VARINT_BITS do
		local byte = self:readBits(8)
		result = bit32.bor(result, bit32.lshift(bit32.band(byte, 0x7F), shift))

		if bit32.band(byte, 0x80) == 0 then
			return result
		end

		shift += 7
	end

	error("VarInt overflow")
end

--// INT
function BitBuffer:writeInt(n: number)
	self:writeVarInt(zigzagEncode(n))
end

function BitBuffer:readInt(): number
	return zigzagDecode(self:readVarInt())
end

--// FLOAT (F32 OPTIMIZED)
function BitBuffer:writeFloat(n: number)
	self:alignToByte()
	local index = self.writePos // 8

	self:_ensureBits(self.writePos + 32)
	BufferUtil.write(self.buffer, "f32", index, n)

	self.writePos += 32
end

function BitBuffer:readFloat(): number
	self:alignReadToByte()

	local index = self.readPos // 8
	self.readPos += 32

	return BufferUtil.read(self.buffer, "f32", index)
end

--// VECTOR3 (PACKED)
function BitBuffer:writeVector3(v)
	self:writeInt(math.floor(v.X * 100))
	self:writeInt(math.floor(v.Y * 100))
	self:writeInt(math.floor(v.Z * 100))
end

function BitBuffer:readVector3()
	return Vector3.new(
		self:readInt() / 100,
		self:readInt() / 100,
		self:readInt() / 100
	)
end

--// STRING
function BitBuffer:writeString(str: string)
	self:alignToByte()

	local len = #str
	self:writeVarInt(len)

	local index = self.writePos // 8
	self:_ensureBits(self.writePos + len * 8)

	for i = 1, len do
		BufferUtil.write(self.buffer, "u8", index + i - 1, str:byte(i))
	end

	self.writePos += len * 8
end

function BitBuffer:readString(): string
	self:alignReadToByte()

	local len = self:readVarInt()
	local index = self.readPos // 8

	local chars = table.create(len)
	for i = 1, len do
		chars[i] = string.char(BufferUtil.read(self.buffer, "u8", index + i - 1))
	end

	self.readPos += len * 8
	return table.concat(chars)
end

--// VALUE (FAST TYPES)
function BitBuffer:writeValue(value, seen)
	seen = seen or {}

	if value == nil then
		self:writeBits(TYPE_NIL, 3)

	elseif type(value) == "boolean" then
		self:writeBits(TYPE_BOOL, 3)
		self:writeBool(value)

	elseif type(value) == "number" then
		if math.floor(value) == value then
			self:writeBits(TYPE_INT, 3)
			self:writeInt(value)
		else
			self:writeBits(TYPE_FLOAT, 3)
			self:writeFloat(value)
		end

	elseif type(value) == "string" then
		self:writeBits(TYPE_STRING, 3)
		self:writeString(value)

	elseif typeof(value) == "Vector3" then
		self:writeBits(TYPE_VECTOR3, 3)
		self:writeVector3(value)

	elseif type(value) == "table" then
		self:writeBits(TYPE_TABLE, 3)
		self:writeTable(value, seen)

	else
		error("Unsupported type")
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
		return self:readString()
	elseif typeTag == TYPE_VECTOR3 then
		return self:readVector3()
	elseif typeTag == TYPE_TABLE then
		return self:readTable()
	end

	error("Unknown type")
end

--// TABLE
function BitBuffer:writeTable(tbl, seen)
	if seen[tbl] then error("Circular table") end
	seen[tbl] = true

	local arrayMode = isArray(tbl)
	self:writeBool(arrayMode)

	if arrayMode then
		local len = #tbl
		self:writeVarInt(len)
		for i = 1, len do
			self:writeValue(tbl[i], seen)
		end
	else
		local keys = {}
		for k in pairs(tbl) do table.insert(keys, k) end
		table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)

		self:writeVarInt(#keys)
		for _, k in ipairs(keys) do
			self:writeValue(k, seen)
			self:writeValue(tbl[k], seen)
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

--// MULTI
function BitBuffer:write(...)
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

	local t = table.create(n)
	for i = 1, n do
		t[i] = self:readValue()
	end

	return table.unpack(t, 1, n)
end

--// META
function BitBuffer:getBuffer(): buffer
	return self.buffer
end

function BitBuffer:getByteLength(): number
	return math.ceil(self.writePos / 8)
end

function BitBuffer:setBuffer(buff: buffer, bitLength: number?)
	self.buffer = buff
	self.readPos = 0
	self.writePos = bitLength or (BufferUtil.len(buff) * 8)
end

function BitBuffer:reset()
	self.readPos = 0
end

return BitBuffer