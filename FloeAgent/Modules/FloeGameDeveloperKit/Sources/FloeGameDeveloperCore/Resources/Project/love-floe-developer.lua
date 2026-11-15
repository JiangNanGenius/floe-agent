-- SPDX-License-Identifier: MPL-2.0
-- Project-side LÖVE registration API. The reviewed love.js runtime exposes no
-- general Lua-to-JS state call, so a host bridge must be added by the project
-- build (or use this module from a project-specific transport). The module
-- itself only exposes bounded getters/setters; it never evals or touches host
-- files.
local FloeDeveloper = {
  version = "1.0.0",
  fields = {},
  actions = {},
  values = {}
}

local function valid_id(id)
  return type(id) == "string" and id:match("^[a-z][A-Za-z0-9_.-]*$") ~= nil
end

function FloeDeveloper.register(descriptor)
  if type(descriptor) ~= "table" then return false end
  if type(descriptor.fields) == "table" then
    for _, field in ipairs(descriptor.fields) do
      if valid_id(field.id) and type(field.get) == "function" then
        FloeDeveloper.fields[field.id] = {
          id = field.id, kind = field.kind or "number",
          label = field.label or field.id, group = field.group or "Project",
          get = field.get, set = field.set
        }
      end
    end
  end
  if type(descriptor.actions) == "table" then
    for _, action in ipairs(descriptor.actions) do
      if valid_id(action.id) and type(action.invoke) == "function" then
        FloeDeveloper.actions[action.id] = {
          id = action.id, label = action.label or action.id,
          invoke = action.invoke
        }
      end
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
  if type(values) ~= "table" then return false end
  for id, value in pairs(values) do
    local field = FloeDeveloper.fields[id]
    if field and type(field.set) == "function" then
      local ok = pcall(field.set, value)
      if not ok then return false end
    end
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
