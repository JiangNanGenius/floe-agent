// SPDX-License-Identifier: MPL-2.0
// Optional microStudio project overlay. The upstream player calls these
// project-defined functions through the existing bridge. Values are primitive
// numbers only; named developer fields can be added by the project.

// Named state is the preferred contract: the bridge returns "named" and
// native writes call floe_restore_named with the full named object.
floe_state = object
floe_state.score = 0
floe_state.lives = 3
floe_state.speed = 1

floe_snapshot = function()
  return floe_state
end

floe_restore_named = function(named)
  floe_state.score = named.score
  floe_state.lives = named.lives
  floe_state.speed = named.speed
  return 1
end

// Legacy array contract remains available for older projects.
floe_snapshot_array = function()
  return [floe_state.score, floe_state.lives]
end

floe_restore = function(score, lives)
  floe_state.score = score
  floe_state.lives = lives
  return true
end
