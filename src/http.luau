local HttpService = game:GetService("HttpService")

type Listener<A...> = (A...) -> ()
type queueItem<A...> = {
	resolved: Listener<A...>,
	rejected: Listener<string>,
	next: {
		resolve: (A...) -> (),
		reject: (string) -> ()
	}
}
type Promise<A...> = {
	after: (onResolve: Listener<A...>?, onReject: Listener<string>?) -> Promise<A...>,
	catch: (onReject: Listener<string>) -> Promise<A...>,
	finally: (onFinally: () -> ()) -> Promise<A...>,
	await: () -> A...,
}

export type method = "GET" | "POST" | "PUT" | "DELETE" | "HEAD" | "OPTIONS"
export type response = {
	success: boolean,
	status: number,
	message: string,
	headers: { [string]: string },
	body: string,
}
export type options = {
	url: string,
	method: method,
	headers: { [string]: string },
	body: string,
	compress: boolean,
	convertJson: boolean
}

export type http = {
	request: ((url: string) -> Promise<response>) &
	((url: string, options: options?) -> Promise<response>) &
	((method: method, url: string, options: options?) -> Promise<response>),
	get: (url: string, options: options?) -> Promise<response>,
	post: (url: string, options: options?) -> Promise<response>,
	put: (url: string, options: options?) -> Promise<response>,
	delete: (url: string, options: options?) -> Promise<response>,
	head: (url: string, options: options?) -> Promise<response>,
	options: (url: string, options: options?) -> Promise<response>
}

local function promise(executor: (resolve: (...any) -> (), reject: (err: string) -> ()) -> ()): Promise<...any>
	local state: "pending" | "resolved" | "rejected" = "pending"
	local result = {}
	local queue = {}

	local function noop(...) return ... end

	local function process()
		if state == "pending" then return end
		for _, exe in queue do
			local callback = if state == "resolved" then exe.resolved else exe.rejected
			local success, res = pcall(callback, table.unpack(result))

			if exe.next then
				if success then
					exe.next.resolve(res)
				else
					exe.next.reject(res)
				end
			end
		end
		queue = {}
	end

	local function resolve(...: any)
		if state ~= "pending" then return end
		state = "resolved"
		result = { ... }
		process()
	end

	local function reject(err: string)
		if state ~= "pending" then return end
		state = "rejected"
		result = { err }
		process()
	end

	local function after(onResolve, onReject)
		onResolve = onResolve or noop
		onReject = onReject or noop
		return promise(function(nextResolve, nextReject)
			table.insert(queue, {
				resolved = function(...) onResolve(...) return ... end,
				rejected = function(err) onReject(err) return err end,
				next = { resolve = nextResolve, reject = nextReject }
			})

			if state ~= "pending" then process() end
		end)
	end

	local function catch(onReject)
		return after(nil, onReject)
	end

	local function finally(onFinally)
		return after(onFinally, onFinally)
	end

	local function await()
		local co = coroutine.running()
		after(function(...)
			coroutine.resume(co, ...)
		end).catch(function(...)
			coroutine.resume(co, nil, ...)
		end)
		return coroutine.yield()
	end

	task.spawn(xpcall, executor, reject, resolve, reject)

	return {
		after = after,
		catch = catch,
		finally = finally,
		await = await,
	}
end

local function urlEncode(str: string): string
	return HttpService:UrlEncode(str)
end

local function createUrl(
	scheme: "http" | "https",
	host: string,
	port: number?,
	path: string?,
	query: { [string]: string }?
): string
	local port = port and (port ~= 80 and port ~= 443) and (":" .. port) or ""
	local path = path or "/"
	local baseUrl = `{scheme}://{host}{port}{path}`

	if not query then
		return baseUrl
	end

	local queryParts = {}
	for key, value in pairs(query) do
		table.insert(queryParts, string.format("%s=%s", urlEncode(key), urlEncode(value)))
	end
	local queryString = table.concat(queryParts, "&")

	return baseUrl .. "?" .. queryString
end

local function parseUrl(url: string)
	local parsed = {}

	local scheme = url:match("^(%w+):") -- Pattern to capture the scheme (e.g., http, https)
	local remainder = url:match("^%w+://(.+)$") -- Remove the scheme and '://' from the URL
	local host = remainder:match("^([%w%.%-]+)") -- Pattern to capture the subdomain (if any), domain, and top-level domain
	local port = remainder:match(":(%d+)") -- Extract the port (if any)
	local path = remainder:match("^[%w%.%-]+[:%d]*(/[^%?]*)") -- Extract the path (if any)
	local queryString = remainder:match("%?(.+)") -- Extract the query string (if any)
	
	parsed.scheme = scheme
	parsed.host = host
	parsed.port = port and tonumber(port) or nil	
	parsed.path = path or "/"
	parsed.query = nil

	if not queryString then return parsed end

	local query = {}
	for key, value in queryString:gmatch("([^&=?]+)=([^&=?]+)") do
		query[key] = value
	end
	parsed.query = query

	return parsed
end

local function request(...): Promise<response>
	local len = select("#", ...)
	local argv =
		len == 1 and { "GET", select(1, ...), {} } or
		len == 2 and { "GET", select(1, ...), select(2, ...) or {} } or
		len == 3 and { select(1, ...), select(2, ...), select(3, ...) or {} }
	local method, url, opts = argv[1], argv[2], argv[3]

	local parsedUrl = parseUrl(url)
	if opts.query and not parsedUrl.query then
		parsedUrl.query = opts.query
	end
	url = createUrl(
		"http",
		parsedUrl.host,
		parsedUrl.port,
		parsedUrl.path,
		parsedUrl.query
	)
	
	local requestParams = {
		Url = url,
		Method = method,
		Headers = opts.headers,
		Body = opts.body,
	}

	
	return promise(function(resolve, reject)
		local response = HttpService:RequestAsync(requestParams)
		local failed = 
			response.StatusCode >= 400 and
			response.StatusCode <= 511

		if failed then
			reject(response.StatusMessage)
		else
			local body = response.Body
			if opts.convertJson then
				promise(function(r)
					r(HttpService:JSONDecode(response.Body))
				end).after(function(result)
					body = result
				end).catch(reject)
			end
			resolve({
				success = true,
				status = response.StatusCode,
				message = response.StatusMessage,
				headers = response.Headers,
				body = body,
			})
		end
	end)
end

local function get(url: string, options: options?)
	return request("GET", url, options)
end
local function post(url: string, options: options?)
	return request("POST", url, options)
end
local function put(url: string, options: options?)
	return request("PUT", url, options)
end
local function delete(url: string, options: options?)
	return request("DELETE", url, options)
end
local function head(url: string, options: options?)
	return request("HEAD", url, options)
end
local function options(url: string, options: options?)
	return request("OPTIONS", url, options)
end

return {
	request = request,
	get = get,
	post = post,
	put = put,
	delete = delete,
	head = head,
	options = options,
} :: http