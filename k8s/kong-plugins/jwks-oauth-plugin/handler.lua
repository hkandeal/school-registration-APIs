local kong_meta = require "kong.meta"
local openidc = require("kong.plugins.jwks-oauth-plugin.openidc")
local az = require("kong.plugins.jwks-oauth-plugin.authorization")
local utils = require("kong.plugins.oidc.utils")
local filter = require("kong.plugins.oidc.filter")
local sc = require("kong.plugins.jwks-oauth-plugin.scopevalidation")
local singletons = kong

local cjson = require("cjson")
local get_method = ngx.req.get_method
local req_set_header = ngx.req.set_header
local req_clear_header = ngx.req.clear_header
local next = next

local JwksAwareJwtAccessTokenHandler = {
  VERSION = kong_meta.version,
  PRIORITY = 1000,
}

local function extract(config) 
  local jwt
  local err
  local header = ngx.req.get_headers()[config.token_header_name]
  
  if header == nil then
    err = "No token found using header: " .. config.token_header_name
    ngx.log(ngx.ERR, err)
    return nil, err
  end
  
  if header:find(" ") then
    local divider = header:find(' ')
    if string.lower(header:sub(0, divider-1)) == string.lower("Bearer") then
      jwt = header:sub(divider+1)
      if jwt == nil then
        err = "No Bearer token value found from header: " .. config.token_header_name
        ngx.log(ngx.ERR, err)
        return nil, err
      end
    end
  end
  
  if jwt == nil then
    jwt =  header
  end
  
  ngx.log(ngx.DEBUG, "JWT token located using header: " .. config.token_header_name .. ", token length: " .. string.len(jwt))
  return jwt, err
end

local function updateHeaders(config, token)
  req_clear_header(config.token_header_name) -- Clear Original header from request
  ngx.log(ngx.DEBUG, "Setting header: " .. config.upstream_jwt_header_name .. " with validated token")
  req_set_header(config.upstream_jwt_header_name, token)
end

local function validateTokenContents(config, token, json)

--  if not config.auto_discover_issuer then
    if config.expected_issuers and next(config.expected_issuers) ~= nil then
      -- validate issuer
      local validated_issuer = false
      local issuer = json["iss"]

      for i, e in ipairs(config.expected_issuers) do
        if issuer ~= nil and issuer ~= '' and string.lower(e) == string.lower(issuer) then
          validated_issuer = true
          ngx.log(ngx.DEBUG, "Successfully validated issuer: " .. e)
          break
        end
      end

      if not validated_issuer then
        -- issuer validation failed.
        utils.exit(ngx.HTTP_UNAUTHORIZED, "Issuer not expected", ngx.HTTP_UNAUTHORIZED)
      end
    end
--  end


  if config.accepted_audiences and next(config.accepted_audiences) ~= nil then
    -- validate audience
    local validated_audience = false
    local audience = json["aud"]

    for i, e in ipairs(config.accepted_audiences) do
      if audience ~= nil and audience ~= '' and string.lower(e) == string.lower(audience) then
        validated_audience = true
        ngx.log(ngx.DEBUG, "Successfully validated audience: " .. e)
        break
      end
    end

    if not validated_audience then
      -- audience validation failed.
      utils.exit(ngx.HTTP_UNAUTHORIZED, "Audience not accepted", ngx.HTTP_UNAUTHORIZED)
    end
  end

end


local function load_consumer(consumer_id)
  ngx.log(ngx.DEBUG, "JwksAwareJwtAccessTokenHandler Attempting to find consumer: " .. consumer_id)
  local result
  local err
  
  if singletons ~= nil and singletons.dao ~= nil then
    result, err = singletons.dao.consumers:find { id = consumer_id }
  elseif singletons ~= nil and singletons.db ~= nil then
    result, err = singletons.db.consumers:find { id = consumer_id }
  elseif kong ~= nil and kong.db ~= nil then
    result, err = kong.db.consumers:find { id = consumer_id }
  else
    err = "Consumer: " .. consumer_id .. " can't be loaded as no known Kong DAO interface available (possible incompatible version)!"
    ngx.log(ngx.ERR, err)
    return nil, err
  end
  
  if not result then
    err = "Consumer: " .. consumer_id .. " not found!"
    ngx.log(ngx.ERR, err)
    return nil, err
  end
  return result
end

function JwksAwareJwtAccessTokenHandler:access(config)
  if not config.run_on_preflight and get_method() == "OPTIONS" then
    ngx.log(ngx.DEBUG, "JwksAwareJwtAccessTokenHandler pre-flight request ignored, path: " .. ngx.var.request_uri)
    return
  end

  if ngx.ctx.authenticated_credential and config.anonymous ~= "" then
    -- already authenticated likely by another auth plugin higher in priority.
    return
  end
  
  if filter.shouldProcessRequest(config) then
    handle(config)
  else
    ngx.log(ngx.DEBUG, "JwksAwareJwtAccessTokenHandler ignoring request, path: " .. ngx.var.request_uri)
  end

  ngx.log(ngx.DEBUG, "JwksAwareJwtAccessTokenHandler execution complete for request: " .. ngx.var.request_uri)
end

function handle(config)
  local token, error = extract(config)
  if token == null or error then
    utils.exit(ngx.HTTP_UNAUTHORIZED, error, ngx.HTTP_UNAUTHORIZED)
  else
    local json, err = openidc.jwt_verify(token, config)
    if token == null or err then
      ngx.log(ngx.ERR, "JwksAwareJwtAccessTokenHandler - failed to validate access token")
      utils.exit(ngx.HTTP_UNAUTHORIZED, err, ngx.HTTP_UNAUTHORIZED)
    else
      ngx.log(ngx.DEBUG, "JwksAwareJwtAccessTokenHandler - Successfully validated access token")
      if config.ensure_consumer_present then
        -- consumer presence is required
        ngx.log(ngx.DEBUG, "Consumer presence is required")
        local cid = json[config.consumer_claim_name]
        if cid == nil or cid == '' then
          -- consumer id claim not read
          ngx.log(ngx.ERR, "Consumer ID could not be read using claim: " .. config.consumer_claim_name)
          utils.exit(ngx.HTTP_UNAUTHORIZED, error, ngx.HTTP_UNAUTHORIZED)
        else
          ngx.log(ngx.DEBUG, "Consumer ID: " .. cid .. " read using claim: " .. config.consumer_claim_name)
          local consumer, e = load_consumer(cid)
          if consumer == null or e then
            -- consumer can't be loaded from Kong
            ngx.log(ngx.ERR, "Consumer ID could not be fetched for cid: " .. cid)
            utils.exit(ngx.HTTP_UNAUTHORIZED, error, ngx.HTTP_UNAUTHORIZED)
          else
            --  consumer succesfully loaded from kong
            ngx.ctx.authenticated_consumer = consumer
            ngx.ctx.authenticated_credential = cid
            req_set_header("X-Consumer-Username", cid)
            updateHeaders(config, token)
            validateTokenContents(config, token, json)
            if config.enable_authorization_rules then
              az.validate_authorization(config, json)
            end
            if config.enable_scope_validation then
              az.validate_scopes(config,json)
            end
          end
        end
      else
        -- consumer presence is not required
        updateHeaders(config, token)
        validateTokenContents(config, token, json)
        if config.enable_authorization_rules then
          az.validate_authorization(config, json)
        end
        if config.enable_scope_validation then
          sc.validate_scopes(config,json)
        end
      end
    end
  end
end

return JwksAwareJwtAccessTokenHandler
