#!/usr/bin/env lua
-- ************************************************************************
--
--    Server program
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

local signal    = require "org.conman.signal"
local exit      = require "org.conman.const.exit"
local syslog    = require "org.conman.syslog"
local fsys      = require "org.conman.fsys"
local magic     = require "org.conman.fsys.magic"
local nfl       = require "org.conman.nfl"
local tls       = require "org.conman.nfl.tls"
local ip        = require "org.conman.parsers.ip-text"
local lpeg      = require "lpeg"
local url       = require "org.conman.parsers.url" * lpeg.P(-1)
local MSG       = require "GLV-1.MSG"

local CONF = {}

magic:flags("mime")

-- ************************************************************************

local parse_address do
  local C = lpeg.C
  local P = lpeg.P
  local R = lpeg.R
  
  local host    = ip.IPv4
                + P"[" * ip.IPv6 * P"]"
                + C(R("!9",";~")^1)
  local port    = P":" * (R"09"^1 / tonumber)
  parse_address = host * port
end

-- ************************************************************************

if #arg == 0 then
  io.stderr:write(string.format("usage: %s confifile\n",arg[0]))
  os.exit(exit.USAGE,true)
end

do
  local conffile,err = loadfile(arg[1],"t",CONF)
  
  if not conffile then
    syslog('critical',"%s: %s",arg[1],err)
    io.stderr:write(string.format("%s: %s\n",arg[1],err))
    os.exit(exit.CONFIG,true)
  end
  
  conffile()
  
  if not CONF.syslog then
    CONF.syslog = { ident = "gemini" , facility = "daemon" }
  else
    CONF.syslog.ident    = CONF.syslog.ident    or "gemini"
    CONF.syslog.facility = CONF.syslog.facility or "daemon"
  end
  
  syslog.open(CONF.syslog.ident,CONF.syslog.facility)
  
  if not CONF.address then
    CONF.address = "[::]:1965"
    CONF._host   = "[::]"
    CONF._port   = 1965
  else
    CONF._host,CONF._port = parse_address:match(CONF.address)
    if not CONF._host or not CONF._port then
      syslog('critical',"%s: syntax error with address",arg[1])
      io.stderr:write(string.format("%s: syntax error with address\n",arg[1]))
      os.exit(exit.CONFIG,true)
    end
  end
  
  if not CONF.hosts then
    syslog('critical',"%s: at least one host needs to be defined",arg[1])
    io.stderr:write(string.format("%s: at least one host needs to be defined\n",arg[1]))
    os.exit(exit.CONFIG,true)
  end
  
  -- ----------------------------------------------------------------------
  -- This expression will canonicalize the address field.  If the host is
  -- missing, it will be replaced with the "all" address.  If the port is
  -- missing, it will be replaced with the default port 1965.  If the host
  -- is '@', it will be replaced by the name of the host.
  -- ----------------------------------------------------------------------
  
  local canon_address do
    local Carg = lpeg.Carg
    local Cc   = lpeg.Cc
    local Cs   = lpeg.Cs
    local P    = lpeg.P
    local R    = lpeg.R
    
    local host    = ip.IPv4
                  + P"[" * ip.IPv6 * P"]"
                  + P"@" / "" * Carg(1)
                  + R("!9",";~")^1
                  + Cc(CONF._host)
    local port    = P":" * R"09"^1
                  + Cc(":" .. CONF._port)
    canon_address = Cs(host * port)
  end
  
  CONF._interfaces = {}
  
  -- -------------------
  -- Process each host.
  -- -------------------
  
  for host,conf in pairs(CONF.hosts) do
    if not conf.certificate then
      syslog('error',"%s: host %q missing certifiate---can't configure host",arg[1],host)
    end
    
    if not conf.keyfile then
      syslog('error',"%s: host %q missing keyfile---can't configure host",arg[1],host)
    end
    
    local addr = conf.address and canon_address:match(conf.address,1,host)
                 or CONF.address
                 
    if conf.certificate and conf.keyfile then
      local info
      
      if not CONF._interfaces[addr] then
        info = {}
        CONF._interfaces[addr] = info
      else
        info = CONF._interfaces[addr]
      end
      
      table.insert(info,{
                cert     = conf.certificate ,
                key      = conf.keyfile ,
                hostinfo = conf ,
        })
    end
    
    conf.language = conf.language or CONF.language
    conf.charset  = conf.charset  or CONF.charset
    
    if not conf.authorization then
      conf.authorization = {}
    end
    
    -- --------------------------------------------
    -- Make sure the redirect tables always exist.
    -- --------------------------------------------
    
    if not conf.redirect then
      conf.redirect = { temporary = {} , permanent = {} , gone = {} }
    else
      conf.redirect.temporary = conf.redirect.temporary or {}
      conf.redirect.permanent = conf.redirect.permanent or {}
      conf.redirect.gone      = conf.redirect.gone      or {}
    end
    
    -- --------------------------------------------------------------------
    -- If we don't have any handlers, make sure they now exist.
    -- If we do have handlers, load them up and initialize them.
    -- --------------------------------------------------------------------
    
    if not conf.handlers then
      syslog('warning',"%s: host %q has no handlers",arg[1],host)
      conf.handlers = {}
    else
      local function notfound()
        return 51,MSG[51],""
      end
      
      local function loadmod(info)
        if not info.path then
          syslog('error',"missing path field in handler")
          info.path = ""
          info.code = { handler = notfound }
          return
        end
        
        if not info.module then
          syslog('error',"%s: missing module field",info.path)
          info.code = { handler = notfound }
          return
        end
        
        local okay,mod = pcall(require,info.module)
        if not okay then
          syslog('error',"%s: %s",info.module,mod)
          info.code = { handler = notfound }
          return
        end
        
        if type(mod) ~= 'table' then
          syslog('error',"%s: module not supported",info.module)
          info.code = { handler = notfound }
          return
        end
        
        info.code = mod
        
        if not mod.handler then
          syslog('error',"%s: missing handler()",info.module)
          mod.handler = notfound
          return
        end
        
        info.language = info.language or conf.language
        info.charset  = info.charset  or conf.charset
        
        if mod.init then
          okay,err = mod.init(info,conf,CONF)
          if not okay then
            syslog('error',"%s: %s",info.module,err)
            mod.handler = notfound
            return
          end
        end
      end
      
      for _,info in ipairs(conf.handlers) do
        loadmod(info)
      end
    end
    
    syslog('info',"host %q configured",host)
  end
  
  if not next(CONF._interfaces) then
    syslog('critical',"%s: at least one host needs to be configured",arg[1])
    io.stderr:write(string.format("%s: at least one host needs to be configured\n",arg[1]))
    os.exit(exit.CONFIG,true)
  end
  
  package.loaded.CONF = CONF
end

-- ************************************************************************

local redirect_subst do
  local replace  = lpeg.C(lpeg.P"$" * lpeg.R"09") * lpeg.Carg(1)
                 / function(c,t)
                     c = tonumber(c:sub(2,-1))
                     return t[c]
                   end
  local char     = replace + lpeg.P(1)
  redirect_subst = lpeg.Cs(char^1)
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
  local value  = R(" .","0\255")^0
  local record = Cg(P"/" * C(name) * P"=" * C(value))
  cert_parse   = Cf(Ct"" * record^1,function(acc,n,v) acc[n] = v return acc end)
               + Ct""
end

-- ************************************************************************

local function reply(ios,...)
  local bytes = 0
  
  for i = 1 , select('#',...) do
    local item = select(i,...)
    bytes = bytes + #tostring(item)
  end
  
  local okay,err = ios:write(...)
  
  if not okay then
    syslog('error',"ios:write() = %s",err)
  end
  
  return bytes
end

-- ************************************************************************

local function log(ios,status,request,bytes,auth)
  syslog(
        'info',
        "remote=%s status=%d request=%q bytes=%d subject=%q issuer=%q",
        ios.__remote.addr,
        status,
        request,
        bytes,
        auth and auth.S or "",
        auth and auth.I or ""
  )
end

-- ************************************************************************

local function setmime(conf,mimetype)
  if not mimetype:find("^text/") then
    return mimetype
  end
  
  local param = ""

  if conf.language and not mimetype:find("language=") then
    param = param .. "; lang=" .. conf.language
  end
  
  if conf.charset and not mimetype:find("charset=") then
    param = param .. "; charset=" .. conf.charset
  end
  
  return mimetype .. param
end

-- ************************************************************************

local function main(ios)
  ios:_handshake()
  
  local request = ios:read("*l")
  if not request then
    log(ios,59,"",reply(ios,"59 ",MSG[59],"\r\n"))
    ios:close()
    return
  end
  
  -- -------------------------------------------------
  -- Current Gemini spec lists URLS max limit as 1024.
  -- -------------------------------------------------
  
  if #request > 1024 then
    log(ios,59,request,reply(ios,"59 ",MSG[59],"\r\n"))
    ios:close()
    return
  end
  
  local loc = url:match(request)
  if not loc then
    log(ios,59,request,reply(ios,"59 ",MSG[59],"\r\n"))
    ios:close()
    return
  end
  
  if not loc.scheme then
    log(ios,59,request,reply(ios,"59 ",MSG[59],"\r\n"))
    ios:close()
    return
  end
  
  if not loc.host then
    log(ios,59,request,reply(ios,"59 ",MSG[59],"\r\n"))
    ios:close()
    return
  end
  
  if loc.scheme ~= 'gemini'
  or not CONF.hosts[loc.host]
  or loc.port   ~= CONF.hosts[loc.host].port then
    log(ios,53,request,reply(ios,"53 ",MSG[53],"\r\n"))
    ios:close()
    return
  end
  
  -- ---------------------------------------------------------------
  -- user portion of a URL is invalid.
  -- ---------------------------------------------------------------
  
  if loc.user then
    log(ios,59,request,reply(ios,"59 ",MSG[59],"\r\n"))
    ios:close()
    return
  end
  
  -- ---------------------------------------------------------------
  -- Relative path resolution is the domain of the client, not the
  -- server.  So reject any requests with relative path elements.
  -- Also check for multiple '//' in a path, which I'm treating
  -- as invalid.
  -- ---------------------------------------------------------------
  
  if loc.path:match "/%.%./" or loc.path:match "/%./" or loc.path:match "//+" then
    log(ios,59,request,reply(ios,"59 ",MSG[59],"\r\n"))
    ios:close()
    return
  end
  
  -- --------------------------------------------------------------
  -- Do our authorization checks.  This way, we can get consistent
  -- authorization checks across handlers.  We do this before anything else
  -- (even redirects) to prevent unintended leakage of data (resources that
  -- might be available under authorization)
  -- --------------------------------------------------------------
  
  local auth =
  {
    _remote = ios.__remote.addr,
    _port   = ios.__remote.port
  }
  
  for _,rule in ipairs(CONF.hosts[loc.host].authorization) do
    if loc.path:match(rule.path) then
      if not ios.__ctx:peer_cert_provided() then
        log(ios,60,request,reply(ios,"60 ",MSG[60],"\r\n"))
        ios:close()
        return
      end
      
      auth._provided = true
      auth._ctx      = ios.__ctx
      auth.I         = ios.__ctx:peer_cert_issuer()
      auth.S         = ios.__ctx:peer_cert_subject()
      auth.issuer    = cert_parse:match(auth.I)
      auth.subject   = cert_parse:match(auth.S)
      auth.notbefore = ios.__ctx:peer_cert_notbefore()
      auth.notafter  = ios.__ctx:peer_cert_notafter()
      auth.now       = os.time()
      
      if auth.now < auth.notbefore then
        log(ios,62,request,reply(ios,"62 ",MSG[62],"\r\n"),auth)
        ios:close()
        return
      end
      
      if auth.now > auth.notafter then
        log(ios,62,request,reply(ios,"62 ",MSG[62],"\r\n"),auth)
        ios:close()
        return
      end
      
      local okay,allowed = pcall(rule.check,auth.issuer,auth.subject,loc)
      if not okay then
        syslog('error',"%s: %s",rule.path,allowed)
        log(ios,40,request,reply(ios,"40 ",MSG[40],"\r\n"),auth)
        ios:close()
        return
      end
      
      if not allowed then
        log(ios,61,request,reply(ios,"61 ",MSG[61],"\r\n"),auth)
        ios:close()
        return
      end
      
      break
    end
  end
  
  -- -------------------------------------------------------------
  -- We handle the various redirections here, the temporary ones,
  -- the permanent ones, and those that are gone gone gone ...
  -- I'm still unsure of the order I want these in ...
  -- -------------------------------------------------------------
  
  for _,rule in ipairs(CONF.hosts[loc.host].redirect.temporary) do
    local match = table.pack(loc.path:match(rule[1]))
    if #match > 0 then
      local new = redirect_subst:match(rule[2],1,match)
      log(ios,30,request,reply(ios,"30 ",new,"\r\n"),auth)
      ios:close()
      return
    end
  end
  
  for _,rule in ipairs(CONF.hosts[loc.host].redirect.permanent) do
    local match = table.pack(loc.path:match(rule[1]))
    if #match > 0 then
      local new = redirect_subst:match(rule[2],1,match)
      log(ios,31,request,reply(ios,"31 ",new,"\r\n"),auth)
      ios:close()
      return
    end
  end
  
  for _,pattern in ipairs(CONF.hosts[loc.host].redirect.gone) do
    if loc.path:match(pattern) then
      log(ios,52,request,reply(ios,"52 ",MSG[52],"\r\n"),auth)
      ios:close()
      return
    end
  end
  
  -- -------------------------------------
  -- Run through our installed handlers
  -- -------------------------------------
  
  for _,info in ipairs(CONF.hosts[loc.host].handlers) do
    local match = table.pack(loc.path:match(info.path))
    if #match > 0 then
      local okay,status,mime,data = pcall(info.code.handler,info,auth,loc,match)
      if not okay then
        log(ios,40,request,reply(ios,"40 ",MSG[40],"\r\n"),auth)
        syslog('error',"request=%s error=%q",request,status)
      else
        log(ios,status,request,reply(ios,status," ",setmime(info,mime),"\r\n",data),auth)
      end
      ios:close()
      return
    end
  end
  
  syslog('error',"no handlers for %q found---possible configuration error?",request)
  log(ios,41,request,reply(ios,"41 ",MSG[41],"\r\n"),auth)
  ios:close()
end

-- ************************************************************************

local function init_interface(interface,info)
  local addr,port = parse_address:match(interface)
  
  local okay,err = tls.listen(addr,port,main,function(conf)
    conf:verify_client_optional()
    conf:insecure_no_verify_cert()
    
    info[1].hostinfo.port = port
    if not conf:keypair_file(info[1].cert,info[1].key) then return false end
    
    for i = 2 , #info do
      info[i].hostinfo.port = port
      if not conf:add_keypair_file(info[i].cert,info[i].key) then
        return false
      end
    end
    
    return conf:protocols "all"
  end)
  
  if not okay then
    syslog('critical',"%s: %s\n",arg[1],err)
    io.stderr:write(string.format("%s: %s\n",arg[1],err))
    os.exit(exit.OSERR,true)
  end
end

-- ************************************************************************

for interface,info in pairs(CONF._interfaces) do
  init_interface(interface,info)
end

signal.catch('int')
signal.catch('term')
syslog('info',"entering service @%s",fsys.getcwd())
nfl.server_eventloop(function() return signal.caught() end)

for host,conf in pairs(CONF.hosts) do
  for _,info in ipairs(conf.handlers) do
    if info.code and info.code.fini then
      local ok,status = pcall(info.code.fini,info)
      if not ok then
        syslog('error',"%s %s: %s",host,info.module,status)
      end
    end
  end
end

os.exit(true,true)
