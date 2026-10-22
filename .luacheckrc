-- luacheck config for the Realistic mod. Game globals below are the ones the ER2 runtime
-- (MoonSharp-hosted Lua 5.1 surface) injects; each is named in docs/verified-api.md or is used by
-- shipping code that has run live. Anything NOT listed here is reported as an undefined global,
-- which is exactly the class of bug check 4c/4d exist for (a nil-global call raises at runtime and
-- silently kills a soldier's brain).
std = "lua51"
max_line_length = false
read_globals = {
  "er2", "vec3", "log", "global", "distance", "sleep", "myself",
  "spawnMissionObjective", "VoiceClip", "spawnVehicle", "spawnSquad", "spawnSquad_script",
  "spawnSquadOnVehicle_script", "sayMissionClip",
}
-- Style noise in a 5,700-line file at the 200-local ceiling; these are not bugs.
ignore = {
  "211/_.*",   -- unused locals prefixed _ (intentional)
  "212",       -- unused argument (callback signatures are fixed by the engine)
  "542",       -- empty if branch (used as documented no-ops)
  "631",       -- line too long
}
files["tests/**/*.lua"] = { std = "+busted", globals = { "arg" }, ignore = { "1", "2", "4", "5", "6" } }
files["spec/**/*.lua"]  = { std = "+busted" }
exclude_files = { "artifacts/**", "missions/**" }
