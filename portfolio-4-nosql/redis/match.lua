-- =====================================================================
-- AquaFlow - Tanker matching, run inside Redis
--
-- Finds the nearest available tankers that are still reporting
-- (heartbeat key exists) and can carry the requested volume.
--
-- KEYS[1] = geo set of available tankers
-- ARGV    = longitude, latitude, radius_km, min_capacity_litres, limit
--
-- Redis runs a Lua script atomically: no other command executes while
-- it runs, so no tanker can change state halfway through the search.
-- =====================================================================
local nearby = redis.call('GEOSEARCH', KEYS[1],
  'FROMLONLAT', ARGV[1], ARGV[2], 'BYRADIUS', ARGV[3], 'km', 'ASC', 'WITHDIST')

local min_capacity = tonumber(ARGV[4])
local limit        = tonumber(ARGV[5])
local matches      = {}

for _, item in ipairs(nearby) do
  local id, distance_km = item[1], item[2]
  if redis.call('EXISTS', 'tanker:' .. id .. ':alive') == 1 then
    local capacity = tonumber(redis.call('HGET', 'tanker:' .. id, 'capacity'))
    if capacity and capacity >= min_capacity then
      table.insert(matches, {
        'tanker ' .. id,
        redis.call('HGET', 'tanker:' .. id, 'plate'),
        capacity .. ' litres',
        distance_km .. ' km'
      })
      if #matches >= limit then break end
    end
  end
end

return matches
