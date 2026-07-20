-- Window layouts, triggered from Raycast via hammerspoon://layout?name=<layout>.
-- Symlinked from nix-conf; edits here auto-reload.

-- Only these apps get moved around; everything else stays put.
local MANAGED = { "Zed", "Claude", "Firefox", "Linear" }

local function screens()
  local primary = hs.screen.primaryScreen()
  for _, s in ipairs(hs.screen.allScreens()) do
    if s ~= primary then return primary, s end
  end
  return primary, primary
end

-- Move every standard window of the managed apps to `screen`, except `hero`.
local function sweep(screen, hero)
  for _, name in ipairs(MANAGED) do
    local app = hs.application.get(name)
    for _, win in ipairs(app and app:allWindows() or {}) do
      if win:isStandard() and win ~= hero then
        win:moveToScreen(screen)
        win:maximize()
      end
    end
  end
end

local function feature(win, screen)
  win:moveToScreen(screen)
  win:maximize()
  win:focus()
end

-- Run layout(hero) once ready() returns the hero window, launching if needed.
local function withHero(ready, launch, layout)
  local hero = ready()
  if hero then return layout(hero) end
  launch()
  hs.timer.waitUntil(ready, function() layout(ready()) end, 0.5)
end

local function findMeetWindow()
  local ff = hs.application.get("Firefox")
  for _, win in ipairs(ff and ff:allWindows() or {}) do
    if (win:title() or ""):find("Meet") then return win end
  end
end

local layouts = {}

-- Meet window on primary, the rest on the second screen.
-- Opens a new Firefox window at meet.google.com if no Meet window exists.
function layouts.call()
  withHero(findMeetWindow, function()
    hs.execute([[open -na Firefox --args --new-window https://meet.google.com]])
  end, function(meet)
    local primary, second = screens()
    sweep(second, meet)
    feature(meet, primary)
    hs.alert.show("Call layout")
  end)
end

-- Claude on primary, the rest on the second screen.
function layouts.claude()
  local claudeWindow = function()
    local app = hs.application.get("Claude")
    return app and app:mainWindow()
  end
  withHero(claudeWindow, function()
    hs.application.launchOrFocus("Claude")
  end, function(claude)
    local primary, second = screens()
    sweep(second, claude)
    feature(claude, primary)
    hs.alert.show("Claude layout")
  end)
end

hs.urlevent.bind("layout", function(_, params)
  local layout = layouts[params.name or ""]
  if layout then layout() else hs.alert.show("No layout: " .. tostring(params.name)) end
end)

-- Reload automatically when this config changes (it's a symlink into nix-conf,
-- so watch the resolved target's directory).
local target = hs.fs.symlinkAttributes(hs.configdir .. "/init.lua", "target")
if target then
  hs.pathwatcher.new(target:match("(.+)/[^/]+$"), hs.reload):start()
end

hs.alert.show("Hammerspoon loaded")
