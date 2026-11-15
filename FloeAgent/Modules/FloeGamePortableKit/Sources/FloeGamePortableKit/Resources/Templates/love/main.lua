-- Original Floe starter for the pinned love.js runtime. No proprietary assets.
local state = {x = 480, y = 320, ticks = 0, pulses = 0}
local font

local function writeState(tag)
  local line = string.format("FLOE_STATE %s x=%.2f y=%.2f ticks=%d pulses=%d version=%s\n",
    tag, state.x, state.y, state.ticks, state.pulses, love.getVersion())
  love.filesystem.write("floe-state.txt", line)
  print(line)
end

function love.load()
  font = love.graphics.newFont(20)
  love.graphics.setFont(font)
  love.window.setTitle("Floe Tidepool")
  print("FLOE_LOVE_BOOT version=" .. table.concat({love.getVersion()}, "."))
  writeState("boot")
end

function love.update(dt)
  state.ticks = state.ticks + 1
  local speed = 240 * dt
  if love.keyboard.isDown("left") then state.x = math.max(24, state.x - speed) end
  if love.keyboard.isDown("right") then state.x = math.min(936, state.x + speed) end
  if love.keyboard.isDown("up") then state.y = math.max(24, state.y - speed) end
  if love.keyboard.isDown("down") then state.y = math.min(616, state.y + speed) end
  if state.ticks % 30 == 0 then writeState("tick") end
end

function love.keypressed(key)
  if key == "escape" then
    writeState("quit")
    love.event.quit()
  elseif key == "s" then
    love.filesystem.write("floe-save.txt", string.format("%.2f,%.2f,%d", state.x, state.y, state.pulses))
    print("FLOE_SAVE_WRITTEN")
  elseif key == "l" then
    local text = love.filesystem.read("floe-save.txt")
    if text then
      local x, y, p = text:match("([^,]+),([^,]+),([^,]+)")
      state.x, state.y, state.pulses = tonumber(x), tonumber(y), tonumber(p)
      print("FLOE_SAVE_LOADED " .. text)
    end
  elseif key == "z" or key == "space" then
    state.pulses = state.pulses + 1
    print("FLOE_PULSE " .. state.pulses)
  elseif key == "x" then
    state.pulses = 0
    print("FLOE_RESET")
  end
end

function love.draw()
  love.graphics.clear(0.03, 0.09, 0.14, 1)
  for i = 0, 24 do
    local a = (i * 0.37 + state.ticks * 0.003) % 1
    love.graphics.setColor(0.18 + a * 0.25, 0.55 + a * 0.2, 0.62, 0.6)
    love.graphics.circle("line", state.x + math.cos(a * 6.28) * (60 + i * 8),
      state.y + math.sin(a * 6.28) * (40 + i * 6), 10 + i * 2)
  end
  love.graphics.setColor(0.86, 0.96, 0.98, 1)
  love.graphics.circle("fill", state.x, state.y, 14)
  love.graphics.setColor(0.95, 0.82, 0.42, 1)
  love.graphics.circle("fill", state.x, state.y, 6)
  love.graphics.setColor(0.9, 0.95, 1, 1)
  love.graphics.print("Floe Tidepool", 24, 20)
  love.graphics.setColor(0.6, 0.8, 0.85, 1)
  love.graphics.print("LÖVE " .. table.concat({love.getVersion()}, ".") ..
    "  x=" .. math.floor(state.x) .. "  pulses=" .. state.pulses, 24, 50)
  love.graphics.print("Arrows move   Z pulse   X reset   S save   L load", 24, 80)
end
