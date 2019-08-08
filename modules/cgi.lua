-- ************************************************************************
--
--    CGI interface.
--    Copyright 2019 by Sean Conner.  All Rights Reserved.
--
--    This program is free software: you can redistribute it and/or modify
--    it under the terms of the GNU General Public License as published by
--    the Free Software Foundation, either version 3 of the License, or
--    (at your option) any later version.
--
--    This program is distributed in the hope that it will be useful,
--    but WITHOUT ANY WARRANTY; without even the implied warranty of
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--    GNU General Public License for more details.
--
--    You should have received a copy of the GNU General Public License
--    along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
--    Comments, questions and criticisms can be sent to: sean@conman.org
--
-- ************************************************************************
-- luacheck: ignore 611
-- RFC-3875

local syslog    = require "org.conman.syslog"
local errno     = require "org.conman.errno"
local fsys      = require "org.conman.fsys"
local process   = require "org.conman.process"
local exit      = require "org.conman.const.exit"
local ios       = require "org.conman.net.ios"
local nfl       = require "org.conman.nfl"
local abnf      = require "org.conman.parsers.abnf"
local lpeg      = require "lpeg"
local io        = require "io"
local os        = require "os"
local string    = require "string"
local coroutine = require "coroutine"
local math      = require "math"
local uurl      = require "url-util"

local pairs     = pairs
local tostring  = tostring
local tonumber  = tonumber

local DEVNULI = io.open("/dev/null","r")
local DEVNULO = io.open("/dev/null","w")

-- ************************************************************************

local parse_headers do
  local Cf = lpeg.Cf
  local Cg = lpeg.Cg
  local Cs = lpeg.Cs
  local Ct = lpeg.Ct
  local C  = lpeg.C
  local P  = lpeg.P
  local R  = lpeg.R
  local S  = lpeg.S
  
  local H do
    local text = R("AZ","az") / function(c) return P(c:lower()) + P(c:upper()) end
               + P(1)         / function(c) return P(c) end
               
    H = function(s)
      local pattern = Cf(text^1,function(acc,pat) return acc * pat end)
      return pattern:match(s) / s
    end
  end
  
  local LWSP         = (abnf.WSP + abnf.CRLF * abnf.WSP)
  local text         = LWSP^1 / " "
                     + abnf.VCHAR
  local ignore       = LWSP + abnf.VCHAR
  local number       = R"09"^1 / tonumber
  local separator    = S'()<>@,;:\\"/[]?={}\t '
  local token        = (abnf.VCHAR - separator)^1
  local status       = H"Status"       * P":" * LWSP * number * ignore^0 * abnf.CRLF
  local content_type = H"Content-Type" * P":" * LWSP * Cs(text^1)        * abnf.CRLF
  local location     = H"Location"     * P":" * LWSP * C(abnf.VCHAR^1)   * abnf.CRLF
  local generic      = C(token)        * P":" * LWSP * C(text^0)         * abnf.CRLF
  local headers      = status + content_type + location + generic
  parse_headers      = Cf(Ct"" * Cg(headers)^1,function(acc,name,value)
                         acc[name] = value
                         return acc
                       end)
                     * abnf.CRLF
end

-- ************************************************************************
-- Handle script command line arguments per RFC-3875 section 4.4
-- ************************************************************************

local parse_cgi_args do
  local xdigit   = lpeg.locale().xdigit
  local char     = lpeg.P"%" * lpeg.C(xdigit * xdigit)
                 / function(c)
                     return string.char(tonumber(c,16))
                   end
                 + (lpeg.R"!~" - lpeg.S' #%<>[\\]^{|}"=&+')
  local args     = lpeg.Cs(char^1) * lpeg.P"+"^-1
  parse_cgi_args = lpeg.Ct(args^1) * lpeg.P(-1)
end

-- ************************************************************************

local cert_parse do
  local Cf = lpeg.Cf
  local Cg = lpeg.Cg
  local Ct = lpeg.Ct
  local C  = lpeg.C
  local P  = lpeg.P
  local R  = lpeg.R
  
  local name   = R("AZ","az")^1
  local value  = R(" .","0\255")^1
  local record = Cg(P"/" * C(name) * P"=" * C(value))
  cert_parse   = Cf(Ct"" * record^1,function(acc,n,v) acc[n] = v return acc end)
end

-- ************************************************************************

local function fdtoios(fd)
  local newfd   = ios()
  newfd.__fd    = fd
  newfd.__co    = coroutine.running()
  
  newfd.close = function(self)
    nfl.SOCKETS:remove(fd)
    self.__fd:close()
    return true
  end
  
  newfd._refill = function()
    return coroutine.yield()
  end
  
  nfl.SOCKETS:insert(fd,'r',function(event)
    if event.read then
      local data,err = fd:read(8192)
      if data then
        if #data == 0 then
          nfl.SOCKETS:remove(fd)
          newfd._eof = true
        end
        nfl.schedule(newfd.__co,data)
      else
        if err ~= errno.EAGAIN then
          syslog('error',"fd:read() = %s",errno[err])
        end
      end
    else
      newfd._eof = true
      nfl.SOCKETS:remove(fd)
      nfl.schedule(newfd.__co)
    end
  end)
  
  return newfd
end

-- ************************************************************************

return function(ssl,remote,program,location,conf)
  local pipe = fsys.pipe()
  if not pipe then
    return 500,"Internal Error",""
  end
  
  pipe.read:setvbuf('no') -- buffering kills the event loop
  
  local child,err = process.fork()
  
  if not child then
    syslog('error',"process.fork() = %s",errno[err])
    return 500,"Internal Error",""
  end
  
  -- =========================================================
  -- The child runs off to do its own thang ...
  -- =========================================================
  
  if child == 0 then
    fsys.redirect(DEVNULI,io.stdin)
    fsys.redirect(pipe.write,io.stdout)
    fsys.redirect(DEVNULO,io.stderr)
    
    -- -----------------------------------------------------------------
    -- Close file descriptors that aren't stdin, stdout or stderr.  Most
    -- Unix systems have dirfd(), right?  Right?  And /proc/self/fd,
    -- right?  Um ... erm ...
    -- -----------------------------------------------------------------
    
    local dir = fsys.opendir("/proc/self/fd")
    if dir and dir._tofd then
      local dirfh = dir:_tofd()
      
      for file in dir.next,dir do
        local fh = tonumber(file)
        if fh > 2 and fh ~= dirfh then
          fsys._close(fh)
        end
      end
      
    -- ----------------------------------------------------------
    -- if all else fails, at least close these to make this work
    -- ----------------------------------------------------------
    
    else
      DEVNULI:close()
      DEVNULO:close()
      pipe.write:close()
      pipe.read:close()
    end
    
    local prog = uurl.rm_dot_segs:match(fsys.getcwd() .. "/" .. program)
    local args = parse_cgi_args:match(location.query or "") or {}
    local env  =
    {
      GATEWAY_INTERFACE = "CGI/1.1",
      QUERY_STRING      = location.query or "",
      REMOTE_ADDR       = remote.addr,
      REMOTE_HOST       = remote.addr,
      REQUEST_METHOD    = "",
      SCRIPT_NAME       = program:sub(2,-1),
      SERVER_NAME       = location.host,
      SERVER_PORT       = tostring(location.port),
      SERVER_PROTOCOL   = "GEMINI",
      SERVER_SOFTWARE   = "GLV-1.12556/1",
    }
    
    if conf.env then
      for var,val in pairs(conf.env) do
        env[var] = val
      end
    end
    
    -- -----------------------------------------------------------------------
    -- The passed in dir is a relative path starting with "./".  So when
    -- searching for dir in location.path, start just past the leading period.
    -- -----------------------------------------------------------------------
    
    local _,e      = location.path:find(program:sub(2,-1),1,true)
    local pathinfo = e and location.path:sub(e+1,-1) or location.path
    
    if pathinfo ~= "" then
      env.PATH_INFO       = pathinfo
      env.PATH_TRANSLATED = fsys.getcwd() .. env.PATH_INFO
    end
    
    -- ===================================================
    
    local function add_http()
      env.REQUEST_METHOD       = "GET"
      env.SERVER_PROTOCOL      = "HTTP/1.0"
      env.HTTP_ACCEPT          = "*/*"
      env.HTTP_ACCEPT_LANGUAGE = "*"
      env.HTTP_CONNECTION      = "close"
      env.HTTP_HOST            = env.SERVER_NAME
      env.HTTP_REFERER         = ""
      env.HTTP_USER_AGENT      = ""
    end
    
    -- ===================================================
    
    local function add_apache()
      env.DOCUMENT_ROOT         = fsys.getcwd()
      env.CONTEXT_DOCUMENT_ROOT = env.DOCUMENT_ROOT
      env.CONTEXT_PREFIX        = ""
      env.SCRIPT_FILENAME       = prog
    end
    
    -- ===================================================
    
    local function add_tlsenv(apache)
      local function breakdown(base,fields)
        for name,value in pairs(fields) do
          env[base .. name] = value
        end
      end
      
      if not ssl:peer_cert_provided() then return end
      
      local notbefore = ssl:peer_cert_notbefore()
      local notafter  = ssl:peer_cert_notafter()
      local now       = os.time()
      local remain    = tostring(math.floor(os.difftime(notafter,now) / 86400))
      local I         = ssl:peer_cert_issuer()
      local S         = ssl:peer_cert_subject()
      local issuer    = cert_parse:match(I)
      local subject   = cert_parse:match(S)
      
      if not apache then
        env.TLS_CIPHER            = ssl:conn_cipher()
        env.TLS_VERSION           = ssl:conn_version()
        env.TLS_CLIENT_HASH       = ssl:peer_cert_hash()
        env.TLS_CLIENT_ISSUER     = I
        env.TLS_CLIENT_SUBJECT    = S
        env.TLS_CLIENT_NOT_BEFORE = os.date("%Y-%m-%dT%H:%M:%SZ",notbefore)
        env.TLS_CLIENT_NOT_AFTER  = os.date("%Y-%m-%dT%H:%M:%SZ",notafter)
        env.TLS_CLIENT_REMAIN     = remain
        
        breakdown("TLS_CLIENT_ISSUER_", issuer)
        breakdown("TLS_CLIENT_SUBJECT_",subject)
        
        env.AUTH_TYPE   = 'Certificate'
        env.REMOTE_USER = env.TLS_CLIENT_SUBJECT_CN
      else
        env.SSL_CIPHER          = ssl:conn_cipher()
        env.SSL_PROTOCOL        = ssl:conn_version()
        env.SSL_CLIENT_I_DN     = I
        env.SSL_CLIENT_S_DN     = S
        env.SSL_CLIENT_V_START  = os.date("%b %d %H:%M:%S %Y GMT",notbefore)
        env.SSL_CLIENT_V_END    = os.date("%b %d %H:%M:%S %Y GMT",notafter)
        env.SSL_CLIENT_V_REMAIN = remain
        env.SSL_TLS_SNI         = env.SERVER_NAME
        
        breakdown("SSL_CLIENT_I_DN_",issuer)
        breakdown("SSL_CLIENT_S_DN_",subject)
        
        env.AUTH_TYPE   = 'Certificate'
        env.REMOTE_USER = env.SSL_CLIENT_S_DN_CN
      end
    end
    
    -- ===================================================
    
    local cwd = conf.cwd
    
    if conf.http     then add_http()              end
    if conf.apache   then add_apache()            end
    if conf.envtls   then add_tlsenv(conf.apache) end
    
    if conf.instance then
      for name,info in pairs(conf.instance) do
        if location.path:match(name) then
          if info.cwd     then cwd = info.cwd            end
          if info.http    then add_http()                end
          if info.apache  then add_apache()              end
          if info.envtls  then add_tlsenv(info.apache)   end
          if info.env then
            for var,val in pairs(info.env) do
              env[var] = val
            end
          end
        end
      end
    end
    
    if cwd then
      local okay,err1 = fsys.chdir(cwd)
      if not okay then
        syslog('error',"CGI cwd(%q) = %s",cwd,errno[err1])
        process.exit(exit.CONFIG)
      end
    end
    
    process.exec(prog,args,env)
    process.exit(exit.OSERR)
  end
  
  -- =========================================================
  -- Meanwhile, back at the parent's place ...
  -- =========================================================
  
  pipe.write:close()
  local inp  = fdtoios(pipe.read)
  local hdrs = inp:read("h")
  local data = inp:read("a")
  inp:close()
  
  local info,err1 = process.wait(child)
  
  if not info then
    syslog('error',"process.wait() = %s",errno[err1])
    return 500,"Internal Error",""
  end
  
  if info.status == 'normal' then
    if info.rc == 0 then
      local headers = parse_headers:match(hdrs)
      
      if headers['Location'] then
        local status = headers['Status'] or 301
        return status,headers['Location'],""
      end
      
      local status  = headers['Status'] or 200
      local mime    = headers['Content-Type'] or "text/plain"
      return status,mime,data
    else
      syslog('warning',"program=%q status=%d",program,info.rc)
      return 500,"Internal Error",""
    end
  else
    syslog('error',"program=%q status=%s description=%s",program,info.status,info.description)
    return 500,"Internal Error",""
  end
end
