request     = require 'request'
requestsync = require 'requestsync'
_           = require 'underscore'


# Default options for request library
defaultRequestOptions =
  pool:
    maxSockets: 100
  followAllRedirects: true

defaultClientOptions =
  maxRetries: 3


# CancellationToken to abort a request
class CancellationToken
  constructor: (@servers, @maxRetries, @retries = 0, @errors = []) ->
    @aborted = false

  setRequest: (req) =>
    @req = req

  isAborted: () =>
    @aborted

  abort: () =>
    @aborted = true
    @req.abort() if @req?

  cancel: @::abort


# HTTP Client for connecting to etcd servers
class Client

  constructor: (@hosts, @sslopts) ->

  execute: (method, options, callback) =>
    opt = _.defaults (_.clone options), defaultRequestOptions, { method: method }
    opt.clientOptions = _.defaults opt.clientOptions, defaultClientOptions

    servers = _.shuffle @hosts
    token = new CancellationToken servers, opt.clientOptions.maxRetries
    helperRequest = @_multiserverHelper servers, opt, token, callback
    if options.synchronous is true
      return helperRequest
    else
      return token


  put: (options, callback) => @execute "PUT", options, callback
  get: (options, callback) => @execute "GET", options, callback
  post: (options, callback) => @execute "POST", options, callback
  patch: (options, callback) => @execute "PATCH", options, callback
  delete: (options, callback) => @execute "DELETE", options, callback

  # Multiserver (cluster) executer
  _multiserverHelper: (servers, options, token, callback) =>
    host = _.first(servers)
    options.url = "#{options.serverprotocol}://#{host}#{options.path}"

    return if token.isAborted() # Aborted by user?

    if not host? # No servers left?
      return @_retry token, options, callback if @_shouldRetry token
      return @_error token, callback

    reqRespHandler = (err, resp, body) =>
      return if token.isAborted()

      if @_isHttpError err, resp
        token.errors.push
          server: host
          httperror: err
          httpstatus: resp?.statusCode
          httpbody: resp?.body
          response: resp
          timestamp: new Date()

        # Recurse:
        return @_multiserverHelper _.rest(servers), options, token, callback

      # Deliver response
      @_handleResponse err, resp, body, callback

    syncRespHandler = (err, body, headers) =>
      msg =
        err: err
        body: body
        headers: headers

    if options.synchronous is true
      req = requestsync options
      callback = syncRespHandler
      reqRespHandler req.err, req.resp, req.body 
    else
      req = request options, reqRespHandler
      token.setRequest req


  _retry: (token, options, callback) =>
    doRetry = () =>
      @_multiserverHelper token.servers, options, token, callback
    waitTime =  @_waitTime token.retries
    token.retries += 1
    setTimeout doRetry, waitTime


  _waitTime: (retries) ->
    return 1 if process.env.RUNNING_UNIT_TESTS is 'true'
    return 100 * Math.pow 16, retries


  _shouldRetry: (token) =>
    token.retries < token.maxRetries and @_isPossibleLeaderElection token.errors


  # All tries (all servers, all retries) failed
  _error: (token, callback) ->
    error = new Error 'All servers returned error'
    error.errors = token.errors
    error.retries = token.retries
    callback error if callback


  # If all servers reject connect or return raft error it's possible the
  # cluster is in leader election mode.
  _isPossibleLeaderElection: (errors) ->
    checkError = (e) ->
      e?.httperror?.code in ['ECONNREFUSED', 'ECONNRESET'] or
        e?.httpbody?.errorCode in [300, 301] or
        /Not current leader/.test e?.httpbody
    errors? and _.every errors, checkError


  _isHttpError: (err, resp) ->
    err or (resp?.statusCode? and resp.statusCode >= 500)


  _handleResponse: (err, resp, body, callback) ->
    return if not callback?
    if body?.errorCode? # http ok, but etcd gave us an error
      error = new Error body?.message || 'Etcd error'
      error.errorCode = body.errorCode
      error.error = body
      callback error, "", (resp?.headers or {})
    else
      callback null, body, (resp?.headers or {})


exports = module.exports = Client
