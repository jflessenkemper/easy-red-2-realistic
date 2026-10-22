-- NEGATIVE FIXTURE: every line below must be flagged by .semgrep/er2.yml (tests/review.sh asserts 5 rule ids).
local DEBUG = true
local uid = 524
local p = me.aiParams
setCallback("soldier_suppressed", function() end)
sq.getAllMembers()
local k = uid % 6
