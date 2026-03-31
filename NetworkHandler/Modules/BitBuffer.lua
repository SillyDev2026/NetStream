--!native
--!optimize 2

-- Node-like internal state is not exposed externally, but helps describe linked behavior

export type BitBuffer = {
	-- Core positions
	writePos: number,
	readPos: number,

	-- Internal buffer
	buffer: buffer,

	-- Byte alignment
	alignToByte: (self: BitBuffer) -> (),
	alignReadToByte: (self: BitBuffer) -> (),

	-- Bit operations
	writeBits: (self: BitBuffer, value: number, bits: number) -> (),
	readBits: (self: BitBuffer, bits: number) -> number,

	-- Primitive types
	writeBool: (self: BitBuffer, b: boolean) -> (),
	readBool: (self: BitBuffer) -> boolean,

	writeVarInt: (self: BitBuffer, n: number) -> (),
	readVarInt: (self: BitBuffer) -> number,

	writeInt: (self: BitBuffer, n: number) -> (),
	readInt: (self: BitBuffer) -> number,

	writeFloat: (self: BitBuffer, n: number) -> (),
	readFloat: (self: BitBuffer) -> number,

	writeString: (self: BitBuffer, str: string) -> (),
	readString: (self: BitBuffer) -> string,

	writeVector3: (self: BitBuffer, v: Vector3) -> (),
	readVector3: (self: BitBuffer) -> Vector3,

	-- Generic value serialization
	writeValue: (self: BitBuffer, value: any, seen: {[any]: boolean}?) -> (),
	readValue: (self: BitBuffer) -> any,

	-- Table serialization
	writeTable: (self: BitBuffer, tbl: {[any]: any}, seen: {[any]: boolean}) -> (),
	readTable: (self: BitBuffer) -> {[any]: any},

	-- Multi-value helpers
	write: (self: BitBuffer, ...any) -> (),
	read: (self: BitBuffer) -> any,

	-- Buffer access
	getBuffer: (self: BitBuffer) -> buffer,
	setBuffer: (self: BitBuffer, buff: buffer, bitLength: number?) -> (),

	-- Utility
	getByteLength: (self: BitBuffer) -> number,
	reset: (self: BitBuffer) -> (),
}

type BitBufferInternal = {
	buffer: buffer,
	writePos: number,
	readPos: number,
}

local BufferUtil = require(script.Parent.BufferUtil)

local BitBuffer = {
	SetBitsBasedOnLies = 8,
}
BitBuffer.__index = BitBuffer

--[[Constants used for encoding and type tagging.]]
local MAX_VARINT_BITS = 35
local SetBitsBasedOnLies = BitBuffer.SetBitsBasedOnLies

local TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_DOUBLE, TYPE_STRING, TYPE_TABLE, TYPE_VECTOR3, TYPE_INSTANCE, TYPE_CFRAME, TYPE_BUFFER =
	0,1,2,3,4,5,6,7,8,9,10

function getInstance(inst: Instance): string
	return inst:GetFullName()
end
--[[Encodes a signed integer using zigzag encoding.
@param n number
@return number]]
function zigzagEncode(n: number): number
	return bit32.bxor(bit32.lshift(n, 1), bit32.rshift(n, 31))
end

--[[Decodes a zigzag-encoded integer.
@param n number
@return number]]
function zigzagDecode(n: number): number
	return bit32.bxor(bit32.rshift(n, 1), -bit32.band(n, 1))
end

--[[Creates a bitmask for a given number of bits.
@param bits number
@return number]]
function mask(bits: number): number
	return (bits == 32) and 0xFFFFFFFF or (bit32.lshift(1, bits) - 1)
end

--[[Checks whether a table is an array (sequential numeric keys starting at 1).
@param tbl table
@return boolean]]
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

--[[Creates a new BitBuffer instance.
@param size number? Initial buffer size in bytes
@return BitBuffer]]
function BitBuffer.new(size: number?): BitBuffer
	local self = setmetatable({}, BitBuffer)
	self.buffer = BufferUtil.new(size or 64)
	self.writePos = 0
	self.readPos = 0
	return self:: BitBuffer
end

--[[Ensures the buffer has enough capacity to store the given number of bits.
@param bitCount number]]
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

--[[Aligns the write position to the next byte boundary by padding with zeros.]]
function BitBuffer:alignToByte()
	local mod = self.writePos % 8
	if mod ~= 0 then
		self:writeBits(0, 8 - mod)
	end
end

--[[Aligns the read position to the next byte boundary.]]
function BitBuffer:alignReadToByte()
	local mod = self.readPos % 8
	if mod ~= 0 then
		self.readPos += (8 - mod)
	end
end

--[[Writes a value using the specified number of bits.
@param value number
@param bits number (1–32)]]
function BitBuffer:writeBits(value: number, bits: number)
	assert(bits > 0 and bits <= 32)

	local bitPos = self.writePos
	local aligned = (bitPos % 8 == 0)
	local index = bitPos // 8

	self:_ensureBits(bitPos + bits)

	value = bit32.band(value, mask(bits))

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

--[[Reads a value using the specified number of bits.
@param bits number (1–32)
@return number]]
function BitBuffer:readBits(bits: number): number
	assert(bits > 0 and bits <= 32)
	assert(self.readPos + bits <= self.writePos, "Read overflow")

	local bitPos = self.readPos
	local aligned = (bitPos % 8 == 0)
	local index = bitPos // 8

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

--[[Writes a boolean value as a single bit.
@param b boolean]]
function BitBuffer:writeBool(b: boolean)
	self:writeBits(b and 1 or 0, 1)
end

--[[Reads a boolean value.
@return boolean]]
function BitBuffer:readBool(): boolean
	return self:readBits(1) == 1
end

--[[Writes a variable-length integer (VarInt).
@param n number]]
function BitBuffer:writeVarInt(n: number)
	while n >= 0x80 do
		self:writeBits(bit32.bor(bit32.band(n, 0x7F), 0x80), 8)
		n = bit32.rshift(n, 7)
	end
	self:writeBits(n, 8)
end

--[[Reads a variable-length integer (VarInt).
@return number]]
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

--[[Writes a signed integer using zigzag encoding.
@param n number]]
function BitBuffer:writeInt(n: number)
	self:writeVarInt(zigzagEncode(n))
end

--[[Reads a signed integer encoded with zigzag.
@return number]]
function BitBuffer:readInt(): number
	return zigzagDecode(self:readVarInt())
end

--[[Writes a 32-bit float (byte-aligned).
@param n number]]
function BitBuffer:writeFloat(n: number)
	self:alignToByte()
	local index = self.writePos // 8

	self:_ensureBits(self.writePos + 32)
	BufferUtil.write(self.buffer, "f32", index, n)

	self.writePos += 32
end

--[[Reads a 32-bit float (byte-aligned).
@return number]]
function BitBuffer:readFloat(): number
	self:alignReadToByte()

	local index = self.readPos // 8
	self.readPos += 32

	return BufferUtil.read(self.buffer, "f32", index)
end

--[[writes a double which is IEEE-754]]
function BitBuffer:writeDouble(n: number)
	self:alignToByte()

	local index = self.writePos // 8
	self:_ensureBits(self.writePos + 64)

	BufferUtil.write(self.buffer, "f64", index, n)
	self.writePos += 64
end

--[[reads the double]]
function BitBuffer:readDouble(): number
	self:alignReadToByte()

	local index = self.readPos // 8
	self.readPos += 64

	return BufferUtil.read(self.buffer, "f64", index)
end

--[[Writes a Vector3 (scaled by 100).
@param v Vector3]]
function BitBuffer:writeVector3(v)
	self:writeInt(math.floor(v.X * 100))
	self:writeInt(math.floor(v.Y * 100))
	self:writeInt(math.floor(v.Z * 100))
end

--[[Reads a Vector3 (scaled by 100).
@return Vector3]]
function BitBuffer:readVector3()
	return Vector3.new(
		self:readInt() / 100,
		self:readInt() / 100,
		self:readInt() / 100
	)
end

function BitBuffer:writeCFrame(cf: CFrame)
	local pos = cf.Position
	local rx, ry, rz = cf:ToEulerAnglesXYZ()
	self:writeVector3(pos)
	self:writeDouble(rx)
	self:writeDouble(ry)
	self:writeDouble(rz)
end

function BitBuffer:readCFrame(): CFrame
	local pos = self:readVector3()
	local rx = self:readDouble()
	local ry = self:readDouble()
	local rz = self:readDouble()
	return CFrame.new(pos) * CFrame.Angles(rx, ry, rz)
end

--[[Writes a string with a length prefix.
@param str string]]
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

--[[Reads a length-prefixed string.
@return string]]
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

function BitBuffer:writeInstance(inst: Instance)
	local path = getInstance(inst)
	self:writeString(path)
end

function searchForInstance(path: string): Instance?
	local curr = game
	for segment in string.gmatch(path, '[^%.]+') do
		curr = curr:FindFirstChild(segment)
		if not curr then return nil end
	end
	return curr
end

function BitBuffer:readInstance(): Instance?
	local path = self:readString()
	return searchForInstance(path)
end

function BitBuffer:writeBuffer(buff: buffer)
	self:alignToByte()

	self:writeVarInt(BufferUtil.len(buff))

	local index = self.writePos // 8
	local len = BufferUtil.len(buff)

	self:_ensureBits(self.writePos + len * 8)

	BufferUtil.copy(self.buffer, index, buff, 0, len)

	self.writePos += len * 8
end

function BitBuffer:readBuffer(): buffer
	self:alignReadToByte()

	local len = self:readVarInt()
	local index = self.readPos // 8

	local newBuff = BufferUtil.new(len)
	BufferUtil.copy(newBuff, 0, self.buffer, index, len)

	self.readPos += len * 8
	return newBuff
end

--[[Writes a dynamically typed value (nil, boolean, number, string, Vector3, table).
@param value any
@param seen table?]]
function BitBuffer:writeValue(value: any, seen)
	seen = seen or {}

	if value == nil then
		self:writeBits(TYPE_NIL, SetBitsBasedOnLies)

	elseif type(value) == "boolean" then
		self:writeBits(TYPE_BOOL, SetBitsBasedOnLies)
		self:writeBool(value)

	elseif type(value) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error('Invalid number')
		end
		if math.floor(value) ~= value or math.abs(value) > 2^30 then
			self:writeBits(TYPE_DOUBLE, SetBitsBasedOnLies)
			self:writeDouble(value)
		else
			self:writeBits(TYPE_INT, SetBitsBasedOnLies)
			self:writeInt(value)
		end

	elseif type(value) == "string" then
		self:writeBits(TYPE_STRING, SetBitsBasedOnLies)
		self:writeString(value)

	elseif typeof(value) == "Vector3" then
		self:writeBits(TYPE_VECTOR3, SetBitsBasedOnLies)
		self:writeVector3(value)

	elseif type(value) == "table" then
		self:writeBits(TYPE_TABLE, SetBitsBasedOnLies)
		self:writeTable(value, seen)
	elseif typeof(value) == 'Instance' then
		self:writeBits(TYPE_INSTANCE, SetBitsBasedOnLies)
		self:writeInstance(value)
	elseif typeof(value) == 'CFrame' then
		self:writeBits(TYPE_CFRAME, SetBitsBasedOnLies)
		self:writeCFrame(value)
	elseif typeof(value) == "buffer" then
		self:writeBits(TYPE_BUFFER, SetBitsBasedOnLies)
		self:writeBuffer(value)
	else
		error("Unsupported type")
	end
end

--[[Reads a dynamically typed value.
@return any]]
function BitBuffer:readValue()
	local typeTag = self:readBits(SetBitsBasedOnLies)

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
	elseif typeTag == TYPE_DOUBLE then
		return self:readDouble()
	elseif typeTag == TYPE_INSTANCE then
		return self:readInstance()
	elseif typeTag == TYPE_CFRAME then
		return self:readCFrame()
	elseif typeTag == TYPE_BUFFER then
		return self:readBuffer()
	end

	error("Unknown type")
end

--[[Writes a table (array or dictionary).
@param tbl table
@param seen table]]
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

--[[Reads a serialized table.
@return table]]
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

--[[Writes multiple values.
@vararg any]]
function BitBuffer:write(...)
	local n = select("#", ...)
	self:writeVarInt(n)
	for i = 1, n do
		self:writeValue(select(i, ...))
	end
end

--[[Reads multiple values.
@return any...]]
function BitBuffer:read(): any
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

--[[Returns the internal buffer.
@return buffer]]
function BitBuffer:getBuffer(): buffer
	return self.buffer
end

--[[Returns the used byte length of the buffer.
@return number]]
function BitBuffer:getByteLength(): number
	return math.ceil(self.writePos / 8)
end

--[[Replaces the buffer and resets read/write positions.
@param buff buffer
@param bitLength number?]]
function BitBuffer:setBuffer(buff: buffer, bitLength: number?)
	self.buffer = buff
	self.readPos = 0
	self.writePos = bitLength or (BufferUtil.len(buff) * 8)
end

--[[Resets the buffer read and write positions.]]
function BitBuffer:reset()
	self.readPos = 0
	self.writePos = 0
	BufferUtil.clear(self.buffer)
end

return BitBuffer
