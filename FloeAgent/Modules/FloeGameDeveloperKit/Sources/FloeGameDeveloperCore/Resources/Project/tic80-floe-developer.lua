-- SPDX-License-Identifier: MPL-2.0
-- Project-side TIC-80 registration API for a cart that is rebuilt with a host
-- bridge. The reviewed TIC-80 player owns its Lua VM and exposes no JS state
-- call, so this module is inert unless the cart/host adds that transport. It
-- provides bounded getters/setters/actions and no eval or file access.
local FloeDeveloper = { version = "1.0.0", fields = {}, actions = {} }

local function valid_id(id)
  return type(id) == "string" and id:match("^[a-z][A-Za-z0-9_.-]*$") ~= nil
end

function FloeDeveloper.register(descriptor)
  if type(descriptor) ~= "table" then return false end
  for _, field in ipairs(descriptor.fields or {}) do
    if valid_id(field.id) and type(field.get) == "function" then
      FloeDeveloper.fields[field.id] = field
    end
  end
  for _, action in ipairs(descriptor.actions or {}) do
    if valid_id(action.id) and type(action.invoke) == "function" then
      FloeDeveloper.actions[action.id] = action
    end
  end
  return true
end

function FloeDeveloper.snapshot()
  local output = {}
  for id, field in pairs(FloeDeveloper.fields) do
    local ok, value = pcall(field.get)
    if ok and (type(value) == "number" or type(value) == "string" or type(value) == "boolean") then
      output[id] = value
    end
  end
  return output
end

function FloeDeveloper.restore(values)
  for id, value in pairs(values or {}) do
    local field = FloeDeveloper.fields[id]
    if field and field.set then pcall(field.set, value) end
  end
  return true
end

function FloeDeveloper.action(id, args)
  local action = FloeDeveloper.actions[id]
  if not action then return false end
  local ok, result = pcall(action.invoke, args or {})
  return ok and result ~= false
end

return FloeDeveloper
