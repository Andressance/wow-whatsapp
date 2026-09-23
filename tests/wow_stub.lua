-- A minimal stand-in for the WoW addon environment, enough to load and drive
-- WoWClaude.lua outside the game (see addon_test.js). Frames are plain tables:
-- capitalized names that aren't listed below resolve to a no-op method, so any
-- SetFoo/EnableBar call is accepted; lowercase names are ordinary fields.
--
-- STUB collects what the addon did: frames, texts, timers, tickers, prints.

STUB = {
	frames = {}, texts = {}, timers = {}, tickers = {}, prints = {}, bindings = {},
	now = 1000, epoch = 1700000000, sounds = {}, loaded = {}, reloaded = false,
}

local function noop() end

local Methods = {}
local FrameMT = {
	__index = function(t, k)
		if type(k) == "string" and k:match("^%u") then
			return Methods[k] or noop
		end
	end,
}

local function NewObject(kind, name, parent)
	local o = setmetatable({ kind = kind, name = name, parent = parent, scripts = {}, hooks = {}, events = {}, shown = true, textures = {}, children = {} }, FrameMT)
	if name then _G[name] = o end
	if parent and type(parent) == "table" and parent.children then table.insert(parent.children, o) end
	return o
end

function Methods.SetScript(self, name, fn) self.scripts[name] = fn end
function Methods.GetScript(self, name) return self.scripts[name] end
function Methods.HookScript(self, name, fn) self.hooks[name] = self.hooks[name] or {}; table.insert(self.hooks[name], fn) end
function Methods.RegisterEvent(self, ev) self.events[ev] = true end
function Methods.UnregisterEvent(self, ev) self.events[ev] = nil end
function Methods.Show(self) self.shown = true end
function Methods.Hide(self)
	local was = self.shown
	self.shown = false
	if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Methods.SetShown(self, v) if v then self:Show() else self:Hide() end end
function Methods.IsShown(self) return self.shown end
function Methods.IsVisible(self) return self.shown end
function Methods.SetText(self, t) self.text = t; table.insert(STUB.texts, tostring(t)) end
function Methods.GetText(self) return self.text or "" end
function Methods.GetName(self) return self.name end
function Methods.GetParent(self) return self.parent end
function Methods.GetWidth(self) return self.width or 400 end
function Methods.GetHeight(self) return self.height or 300 end
function Methods.SetSize(self, w, h) self.width, self.height = w, h end
function Methods.SetWidth(self, w) self.width = w end
function Methods.SetHeight(self, h) self.height = h end
function Methods.GetSize(self) return self:GetWidth(), self:GetHeight() end
function Methods.GetStringHeight(self) return 14 end
function Methods.GetStringWidth(self) return 100 end
function Methods.GetFontString(self) return self end
function Methods.GetPoint(self) return "CENTER", nil, "CENTER", 0, 0 end
function Methods.SetPoint(self, point, rel, relPoint, x, y)
	if type(rel) == "number" then x, y = rel, relPoint end
	self.x, self.y = x or 0, y or 0
end
function Methods.GetVerticalScrollRange(self) return 0 end
function Methods.CreateTexture(self, name, layer)
	local t = NewObject("Texture", name, self)
	table.insert(self.textures, t)
	return t
end
function Methods.CreateFontString(self, name) return NewObject("FontString", name, self) end
function Methods.CreateAnimationGroup(self) return NewObject("AnimationGroup", nil, self) end
function Methods.CreateAnimation(self) return NewObject("Animation", nil, self) end
function Methods.IsPlaying(self) return self.playing or false end
function Methods.Play(self) self.playing = true end
function Methods.Stop(self) self.playing = false end
function Methods.SetColorTexture(self, r, g, b, a) self.color = { r, g, b, a } end
function Methods.SetTexture(self, path) self.texture = path; return true end
function Methods.GetTexture(self) return self.texture end
function Methods.SetBackdrop(self, t)
	-- The real client would silently draw nothing; make it a test failure instead.
	assert(type(t) == "table", "SetBackdrop called with " .. tostring(t) .. " on " .. tostring(self.name or self.kind))
	self.backdrop = t
end
function Methods.SetFocus(self) STUB.focus = self end
function Methods.ClearFocus(self) if STUB.focus == self then STUB.focus = nil end end
function Methods.GetEditBox(self) return self.editBox end

function CreateFrame(kind, name, parent, template)
	local f = NewObject(kind, name, parent)
	f.template = template
	table.insert(STUB.frames, f)
	return f
end

-- Fire an event on every frame that registered for it.
function STUB.FireEvent(ev, ...)
	for _, f in ipairs(STUB.frames) do
		if f.events[ev] and f.scripts.OnEvent then f.scripts.OnEvent(f, ev, ...) end
	end
end

-- Run every C_Timer.After callback that is due, then every ticker once.
function STUB.RunTimers()
	local due = STUB.timers
	STUB.timers = {}
	for _, t in ipairs(due) do t.fn() end
end
function STUB.Tick()
	for _, fn in ipairs(STUB.tickers) do fn() end
end

UIParent = CreateFrame("Frame", "UIParent")
GameTooltip = CreateFrame("Frame", "GameTooltip")
UIErrorsFrame = CreateFrame("Frame", "UIErrorsFrame")
ChatFontNormal = {}
OKAY, CANCEL = "Okay", "Cancel"
NUM_CHAT_WINDOWS = 1
StaticPopupDialogs = {}
function StaticPopup_Show(which, a, b, data) STUB.popup = { which = which, data = data } end
SlashCmdList = {}
UISpecialFrames = {}
tinsert = table.insert
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function hooksecurefunc(a, b, c)
	if type(a) == "table" then
		local orig = a[b]
		a[b] = function(...) local r = orig(...); c(...); return r end
	else
		local orig = _G[a]
		_G[a] = function(...) local r = orig(...); b(...); return r end
	end
end
function InCombatLockdown() return false end
function ReloadUI() STUB.reloaded = true end
function GetTime() return STUB.now end
function time() return STUB.epoch + math.floor(STUB.now) end
function date(fmt, t) return "12:00" end
C_Timer = {
	After = function(delay, fn) table.insert(STUB.timers, { delay = delay, fn = fn }) end,
	NewTicker = function(delay, fn) table.insert(STUB.tickers, fn); return { Cancel = noop } end,
}
C_AddOns = {
	IsAddOnLoaded = function(name) return STUB.loaded[name] or false end,
	LoadAddOn = function(name)
		STUB.loaded[name] = true
		if STUB.onLoadAddOn then STUB.onLoadAddOn(name) end
		return true
	end,
}
C_Texture = { GetAtlasExists = function() return true end }
function PlaySound() end
function PlaySoundFile(path) if STUB.sounds[path] then return true, 1 end return false end
function StopSound() end
function GetPhysicalScreenSize() return 1920, 1080 end
function SetBinding(key, cmd) STUB.bindings[key] = cmd end
function SaveBindings() end
function GetCurrentBindingSet() return 1 end
function SetItemRef() end
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	table.insert(STUB.prints, table.concat(parts, " "))
end
