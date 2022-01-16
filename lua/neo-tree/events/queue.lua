local utils = require("neo-tree.utils")
local log = require("neo-tree.log")

-- First in Last Out
Queue = {}
function Queue:new()
  local props = { first = 0, last = -1 }
  setmetatable(props, self)
  self.__index = self
  return props
end

---Add an element to the end of the queue.
---@param value any The value to add.
function Queue:add(value)
  local last = self.last + 1
  self.last = last
  self[last] = value
end

function Queue:is_empty()
  return self.first > self.last
end

---Remove the first element from the queue.
---@return any any The first element of the queue.
function Queue:remove()
  local first = self.first
  if self:is_empty() then
    error("list is empty")
  end
  local value = self[first]
  self[first] = nil -- to allow garbage collection
  self.first = first + 1
  return value
end

function Queue:without(id)
  local first = self.first
  local last = self.last
  local new_queue = Queue:new()
  for i = first, last do
    local item = self[i]
    if item ~= nil then
      local item_id = item.id or item
      if item_id ~= id and not item.cancelled then
        new_queue:add(item)
      end
    end
  end
  return new_queue
end

local event_queues = {}
local event_definitions = {}
local M = {}

local validate_event_handler = function(event_handler)
  if type(event_handler) ~= "table" then
    error("Event handler must be a table")
  end
  if type(event_handler.event) ~= "string" then
    error("Event handler must have an event")
  end
  if type(event_handler.handler) ~= "function" then
    error("Event handler must have a handler")
  end
end

M.clear_all_events = function()
  for event_name, queue in pairs(event_queues) do
    M.destroy_event(event_name)
  end
  event_queues = {}
end

M.define_event = function(event_name, opts)
  local existing = event_definitions[event_name]
  if existing ~= nil then
    error("Event already defined: " .. event_name)
  end
  event_definitions[event_name] = opts
end

M.destroy_event = function(event_name)
  local existing = event_definitions[event_name]
  if existing == nil then
    return false
  end
  if existing.setup_was_run and type(existing.teardown) == "function" then
    local success, result = pcall(existing.teardown)
    if not success then
      error("Error in teardown for " .. event_name .. ": " .. result)
    end
    existing.setup_was_run = false
  end
  event_queues[event_name] = nil
  return true
end

local fire_event_internal = function(event, args)
  local queue = event_queues[event]
  if queue == nil then
    return nil
  end
  log.trace("Firing event: " .. event)

  if queue:is_empty() then
    log.trace("Event queue is empty")
    return nil
  end
  local seed = utils.get_value(event_definitions, event .. ".seed")
  if seed ~= nil then
    local success, result = pcall(seed, args)
    if success then
      log.trace("Seed for " .. event .. " returned: " .. tostring(result))
    else
      log.error("Error in seed function for " .. event .. ": " .. result)
    end
  end

  local first = queue.first
  local last = queue.last
  for i = first, last do
    local event_handler = queue[i]
    if not event_handler.cancelled then
      local success, result = pcall(event_handler.handler, args)
      local id = event_handler.id or event_handler
      if success then
        log.trace("Handler ", id, " for " .. event .. " called successfully.")
      else
        log.error(string.format("Error in event handler for event %s[%s]: %s", event, id, result))
      end
      if event_handler.once then
        event_handler.cancelled = true
      end
    end
  end
end

M.fire_event = function(event, args)
  local freq = utils.get_value(event_definitions, event .. ".debounce_frequency", 0, true)
  if freq > 0 then
    utils.debounce("EVENT_FIRED: " .. event, function()
      fire_event_internal(event, args or {})
    end, freq)
  else
    fire_event_internal(event, args or {})
  end
end

M.subscribe = function(event_handler)
  validate_event_handler(event_handler)

  local queue = event_queues[event_handler.event]
  if queue == nil then
    log.debug("Creating queue for event: " .. event_handler.event)
    queue = Queue:new()
    local def = event_definitions[event_handler.event]
    if def and type(def.setup) == "function" then
      local success, result = pcall(def.setup)
      if success then
        def.setup_was_run = true
        log.debug("Setup for event " .. event_handler.event .. " was run")
      else
        log.error("Error in setup for " .. event_handler.event .. ": " .. result)
      end
    end
    event_queues[event_handler.event] = queue
  end
  log.debug("Adding event handler [", event_handler.id, "] for event: ", event_handler.event)
  queue:add(event_handler)
end

M.unsubscribe = function(event_handler)
  local queue = event_queues[event_handler.event]
  if queue == nil then
    return nil
  end
  queue = queue:without(event_handler.id or event_handler)
  if queue:is_empty() then
    M.destroy_event(event_handler.event)
    event_queues[event_handler.event] = nil
  else
    event_queues[event_handler.event] = queue
  end
end

return M
