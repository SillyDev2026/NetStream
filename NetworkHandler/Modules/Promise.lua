--!native
--!optimize 2
local HttpService = game:GetService('HttpService')

local Promise = {}
Promise.__index = Promise

local PENDING, FULFILLED, REJECTED = "PENDING", "FULFILLED", "REJECTED"

type Callback<T> = {
	fulfilled: (T) -> (),
	rejected: (any) -> (),
	resolve: (T) -> (),
	reject: (any) -> ()
}

export type Promise<T> = {
	_state: string,
	_value: T?,
	_callbacks: {Callback<T>},
	andThen: (self: Promise<T>, onFulfilled: ((T) -> T)?, onRejected: ((any) -> T)?) -> Promise<T>,
	catch: (self: Promise<T>, onRejected: (any) -> T) -> Promise<T>,
	finally: (self: Promise<T>, onFinally: () -> ()) -> Promise<T>,
	Error: (self: Promise<T>, onError: (any) -> T?) -> Promise<T>
}

local function retryHelper<T>(executor: (resolve: (T) -> (), reject: (any) -> ()) -> (), remaining: number, delaySeconds: number?, resolve: (T) -> (), reject: (any) -> ())
	Promise.new(executor):andThen(resolve)
		:catch(function(err)
			if remaining > 0 then
				if delaySeconds then
					Promise.delay(delaySeconds):andThen(function()
						retryHelper(executor, remaining - 1, delaySeconds, resolve, reject)
					end)
				else
					retryHelper(executor, remaining - 1, nil, resolve, reject)
				end
			else
				reject(err)
			end
		end)
end

function Promise.new<T>(executor: (resolve: (T) -> (), reject: (any) -> ()) -> ()): Promise<T>
	assert(type(executor) == "function", "Executor must be a function")
	local self: Promise<T> = setmetatable({
		_state = PENDING,
		_value = nil,
		_callbacks = {},
	}, Promise)

	local function resolve(value: T)
		if self._state ~= PENDING then return end
		self._state = FULFILLED
		self._value = value
		self:_flushCallbacks()
	end

	local function reject(reason: any)
		if self._state ~= PENDING then return end
		self._state = REJECTED
		self._value = reason
		self:_flushCallbacks()
	end

	local ok, err = pcall(executor, resolve, reject)
	if not ok then reject(err) end
	return self
end

function Promise:_flushCallbacks()
	local callbacks = self._callbacks
	self._callbacks = {}
	for _, cb in ipairs(callbacks) do
		local fn = self._state == FULFILLED and cb.fulfilled or cb.rejected
		if fn then
			local ok, result = pcall(fn, self._value)
			if not ok and cb.reject then cb.reject(result) end
			if ok and cb.resolve then cb.resolve(result) end
		end
	end
end

function Promise:andThen<T>(onFulfilled: ((T) -> T)?, onRejected: ((any) -> T)?): Promise<T>
	local parent: Promise<T> = self
	return Promise.new(function(resolve, reject)
		if parent._state == FULFILLED then
			local ok, result = pcall(onFulfilled or function(v) return v end, parent._value)
			if ok then resolve(result) else reject(result) end
		elseif parent._state == REJECTED then
			local ok, result = pcall(onRejected or function(e) error(e) end, parent._value)
			if ok then resolve(result) else reject(result) end
		else
			parent._callbacks[#parent._callbacks + 1] = {
				fulfilled = onFulfilled or function(v) return v end,
				rejected = onRejected or function(e) error(e) end,
				resolve = resolve,
				reject = reject
			}
		end
	end)
end

function Promise:catch<T>(onRejected: (any) -> T): Promise<T>
	return self:andThen(nil, onRejected)
end

function Promise:finally<T>(onFinally: () -> ()): Promise<T>
	return self:andThen(
		function(value)
			if onFinally then onFinally() end
			return value
		end,
		function(reason)
			if onFinally then onFinally() end
			error(reason)
		end
	)
end

function Promise:await(): any
	if self._state == "FULFILLED" then
		return self._value
	elseif self._state == "REJECTED" then
		error(self._value)
	else
		local co = coroutine.running()
		assert(co, "Promise:await must be called inside a coroutine")
		self:andThen(function(value)
			task.spawn(function()
				coroutine.resume(co, value)
			end)
		end, function(err)
			task.spawn(function()
				coroutine.resume(co, nil, err)
			end)
		end)
		local ok, result = coroutine.yield()
		if ok == nil then
			error(result)
		end
		return result
	end
end
function Promise:Error<T>(onError: (any) -> T?): Promise<T>
	return self:andThen(nil, function(reason)
		local ok, res = pcall(onError, reason)
		if not ok then error(res) end
		return res
	end)
end

function Promise.resolve<T>(value: T): Promise<T>
	return Promise.new(function(resolve) resolve(value) end)
end

function Promise.all<T>(promises: {Promise<T>}): Promise<{T}>
	return Promise.new(function(resolve, reject)
		local results: {T} = {}
		local count = 0
		local total = #promises
		if total == 0 then resolve(results) return end
		for i, p in ipairs(promises) do
			p:andThen(function(v)
				results[i] = v
				count += 1
				if count == total then resolve(results) end
			end, reject)
		end
	end)
end

function Promise.retry<T>(executor: (resolve: (T) -> (), reject: (any) -> ()) -> (), retries: number): Promise<T>
	return Promise.new(function(resolve, reject)
		retryHelper(executor, retries, nil, resolve, reject)
	end)
end

function Promise.retryDelay<T>(executor: (resolve: (T) -> (), reject: (any) -> ()) -> (), retries: number, delaySeconds: number): Promise<T>
	return Promise.new(function(resolve, reject)
		retryHelper(executor, retries, delaySeconds, resolve, reject)
	end)
end

function Promise.retryAsync<T>(executor: (resolve: (T) -> (), reject: (any) -> ()) -> (), retries: number?, delaySeconds: number?): Promise<T>
	retries = retries or 30
	delaySeconds = delaySeconds or 0.3
	return Promise.new(function(resolve, reject)
		retryHelper(executor, retries, delaySeconds, resolve, reject)
	end)
end

function Promise.delay(seconds: number): Promise<() -> ()>
	return Promise.new(function(resolve) task.delay(seconds, resolve) end)
end

function Promise.timeOut<T>(promise: Promise<T>, seconds: number): Promise<T>
	return Promise.new(function(resolve, reject)
		local timedOut = false
		task.delay(seconds, function()
			timedOut = true
			reject("Promise timed out")
		end)
		promise:andThen(function(v) if not timedOut then resolve(v) end end, function(r) if not timedOut then reject(r) end end)
	end)
end

function Promise.resume<T>(thread: thread): Promise<T>
	return Promise.new(function(resolve, reject)
		local ok, result = coroutine.resume(thread)
		if ok then resolve(result) else reject(result) end
	end)
end

function Promise.wrap<T>(func: (...any) -> T): (...any) -> Promise<T>
	return function(...: any)
		local args = {...}
		return Promise.new(function(resolve, reject)
			local ok, res = pcall(func, table.unpack(args))
			if ok then resolve(res) else reject(res) end
		end)
	end
end

function Promise.repeatUntil<T>(executor: () -> T, delaySeconds: number): Promise<T>
	return Promise.new(function(resolve, reject)
		local ok, res
		repeat
			ok, res = pcall(executor)
			if not ok then task.wait(delaySeconds) end
		until ok
		resolve(res)
	end)
end

function Promise.race<T>(promises: {Promise<T>}): Promise<T>
	return Promise.new(function(resolve, reject)
		for _, p in ipairs(promises) do
			p:andThen(resolve, reject)
		end
	end)
end

function Promise.filter<T>(promises: {Promise<T>}, filterFunc: (T) -> boolean): Promise<{T}>
	return Promise.all(promises):andThen(function(results)
		local filtered: {T} = {}
		for _, v in ipairs(results) do
			if filterFunc(v) then table.insert(filtered, v) end
		end
		return filtered
	end)
end

function Promise.fromEvent<T>(signal: RBXScriptSignal): Promise<T>
	return Promise.new(function(resolve)
		local conn
		conn = signal:Connect(function(...)
			resolve(...)
			conn:Disconnect()
		end)
	end)
end

function Promise.fromEvents<T>(signals: {RBXScriptSignal}): Promise<{T}>
	return Promise.new(function(resolve)
		local results: {T} = {}
		local completed = 0
		local total = #signals
		for i, s in ipairs(signals) do
			s:Connect(function(...)
				results[i] = {...}
				completed += 1
				if completed == total then resolve(results) end
			end)
		end
	end)
end

local LOG_LEVELS = {Debug=true, Info=true, Warn=true, Error=true}
function Promise.LogMessage(level: string, message: string)
	return Promise.new(function(resolve, reject)
		if not LOG_LEVELS[level] then return reject("Invalid log level") end
		local msg = string.format("[PromiseModule] [%s] %s", level, message)
		if level == "Error" then reject(msg); error(msg)
		elseif level == "Warn" then warn(msg)
		else print(msg) end
		resolve(msg)
	end)
end

function Promise.CreateEmbed(embed: {title: string?, description: string?})
	return Promise.new(function(resolve, reject)
		if type(embed) ~= "table" then return reject("Embed must be a table") end
		if embed.title and #embed.title > 256 then return reject("Title too long") end
		if embed.description and #embed.description > 4086 then return reject("Description too long") end
		resolve(embed)
	end)
end

function Promise.sendToDiscord(url: string, data: any, content_type: Enum.HttpContentType?)
	return Promise.new(function(resolve, reject)
		local ok, res = pcall(function()
			local json = HttpService:JSONEncode(data)
			return HttpService:PostAsync(url, json, content_type or Enum.HttpContentType.ApplicationJson)
		end)
		if ok and res then resolve(res) else reject("Failed to send to Discord") end
	end)
end

function Promise.print() print(Promise) end

return Promise
