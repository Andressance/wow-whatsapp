-- WoWClaude: talk to local Claude Code sessions from inside WoW, without reloading.
--
-- The WoW sandbox has no network and no file reads at runtime. Two doors remain open:
--
--   OUT ("pixel" mode): pending messages are drawn as a strip of colored squares in
--        the top-left corner of the screen until the bridge acknowledges them.
--        bridge.js screen-captures that corner and decodes it. Nothing touches the game.
--   IN:  load-on-demand addons read their files from disk at the moment they load.
--        The bridge writes the latest replies for every chat into a pool of pre-made
--        slot addons (WoWClaude_S001..S200); we load a fresh slot from a timer.
--        Each slot is single-use per session; a /reload frees them all.
--   Fallback ("reload" mode): SavedVariables + Inbox.lua, a ReloadUI() per step.
--
-- Chats: each chat is its own Claude session (like a separate terminal) with its own
-- folder, history and pending message. The bridge runs them in parallel.
-- Everything here is plain addon API. No automation, no memory reading.

local ADDON_NAME = ...
local WoWClaude = {}
_G.WoWClaude = WoWClaude
local Codec = WoWClaude_Codec

local DEFAULT_CWD = "" -- empty = the bridge's configured defaultCwd
local MAX_HISTORY = 200
local MAX_CHATS = 16

local SLOT_COUNT = 200
local SLOT_PREFIX = "WoWClaude_S"
local ACT_MAX = 60 -- heartbeat files per message (act/NNN/01..60.wav)
local PRESENCE_MAX = 2000 -- presence/0001..2000.wav, one flipped by the bridge every 30 s
local STRIP_TRIES = 3 -- re-show an unacknowledged message this many times before falling back
local CELL, CELLS_PER_ROW, MAX_ROWS = 4, 200, 48
local STRIP_SECONDS = 40 -- max per message; it leaves the strip as soon as the bridge acknowledges
local POLL_SCHEDULE = { 5, 10, 16, 24, 34, 46, 60, 80, 100, 130, 160, 200, 240, 300 }
local POLL_TAIL = 60
local TICK_SECONDS = 2
local CONNECT_WAIT = 15 -- seconds the Connect button waits for the bridge before giving up
local IDLE_POLL_SECONDS = 600 -- without the sound channel, spend one slot this often while idle to check the bridge
local RS, US = "\30", "\31" -- record / unit separators in the strip payload

local db
local ui = {}
-- Transport state for this UI session. outbound[id] = { chat, cwd, flags, text, sentAt, acked }
local run = { outbound = {} }

-- Shared window backdrop. Declared up here because ShowCopy (rendering section)
-- uses it too: a later `local` would be invisible there and resolve to a nil global.
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local ROLE_STYLE = {
	user   = { label = "You",    color = { 0.49, 0.78, 1.00 }, bg = { 0.25, 0.45, 0.75, 0.16 } },
	claude = { label = "Claude", color = { 1.00, 0.82, 0.25 }, bg = { 0.85, 0.70, 0.30, 0.10 } },
	system = { label = "System", color = { 0.62, 0.62, 0.62 }, bg = { 0.50, 0.50, 0.50, 0.10 } },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ToHex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- EditBoxes do not render UI escape sequences, so just make pipes harmless.
local function Display(s)
	return (tostring(s or ""):gsub("|", "¦"))
end

local function Trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function FmtDur(sec)
	sec = math.floor(sec or 0)
	if sec < 60 then return sec .. "s" end
	if sec < 3600 then return math.floor(sec / 60) .. "m" .. string.format("%02d", sec % 60) .. "s" end
	return math.floor(sec / 3600) .. "h" .. string.format("%02d", math.floor(sec / 60) % 60) .. "m"
end

-- Last path component of a folder, for labels.
local function FolderName(cwd)
	local name = tostring(cwd or ""):gsub("[\\/]+$", ""):match("([^\\/]+)$")
	return name or ""
end

-- The folder a chat works in: its own, or the bridge's default (the folder the
-- bridge was started from), which the bridge reports in every slot file.
local function ChatFolder(c)
	if c and c.cwd ~= "" then return c.cwd end
	return run.bridgeCwd or ""
end

-- First few words of a message, as a chat title.
local function AutoTitle(text)
	local words = {}
	for w in tostring(text or ""):gmatch("%S+") do
		w = w:gsub("^[%p]+", ""):gsub("[%p]+$", "")
		if w ~= "" then
			table.insert(words, w)
			if #words >= 5 then break end
		end
	end
	local title = table.concat(words, " ")
	if #title > 24 then title = title:sub(1, 24):gsub("%s+%S*$", "") end
	if title == "" then return nil end
	return title:sub(1, 1):upper() .. title:sub(2)
end

local function NewId()
	return string.format("%x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF))
end

local function FindChat(id)
	for i, c in ipairs(db.chats) do
		if c.id == id then return c, i end
	end
end

local function ActiveChat()
	return FindChat(db.activeChat)
end

local function AddChat(name, cwd)
	if #db.chats >= MAX_CHATS then return nil end
	local current = ActiveChat()
	local c = {
		id = NewId(),
		name = name or ("Chat " .. (#db.chats + 1)),
		cwd = cwd or (current and current.cwd) or DEFAULT_CWD,
		history = {},
		unread = 0,
		created = time(),
	}
	table.insert(db.chats, c)
	return c
end

local function AnyPending()
	for _, c in ipairs(db.chats) do
		if c.pendingId then return true end
	end
	return false
end

local function InitDB()
	WoWClaudeDB = WoWClaudeDB or {}
	db = WoWClaudeDB
	db.settings = db.settings or {}
	local s = db.settings
	if s.autoRefresh == nil then s.autoRefresh = true end
	if s.signal == nil then s.signal = true end
	s.echo = s.echo or "full" -- how much of each reply to print in the game chat
	s.mode = s.mode or "pixel"
	s.interval = s.interval or 20
	s.cwd = s.cwd or DEFAULT_CWD
	s.width = s.width or 780
	s.height = s.height or 500
	db.lastSeq = db.lastSeq or 0
	-- Chats deleted in game that the bridge hasn't confirmed forgetting yet.
	db.forget = db.forget or {}
	-- Identifies this counter's lifetime. If the saved data is ever reset, a new
	-- session lets the bridge tell "message #1 again" from "message #1, already done".
	if not db.session then
		db.session = string.format("%x%04x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF), math.random(0, 0xFFFF))
	end
	if not db.chats then
		-- Migrate the single-chat layout into the first chat.
		db.chats = {}
		local c = {
			id = NewId(),
			name = "Chat 1",
			cwd = s.cwd,
			history = db.history or {},
			pendingId = db.pendingId,
			unread = db.unread or 0,
			draft = db.draft,
			created = time(),
		}
		table.insert(db.chats, c)
		db.activeChat = c.id
		db.history, db.pendingId, db.unread, db.draft = nil, nil, nil, nil
	end
	if #db.chats == 0 then AddChat() end
	if not FindChat(db.activeChat) then db.activeChat = db.chats[1].id end
end

local function AddHistory(chat, role, text, id, denied)
	table.insert(chat.history, { role = role, text = text, id = id, t = time(), denied = denied })
	while #chat.history > MAX_HISTORY do
		table.remove(chat.history, 1)
	end
end

local function SlotName(i)
	return string.format("%s%03d", SLOT_PREFIX, i)
end

local function SlotNumber(id)
	return ((id - 1) % SLOT_COUNT) + 1
end

---------------------------------------------------------------------------
-- Reload plumbing (fallback path)
---------------------------------------------------------------------------

local function SafeReload()
	if InCombatLockdown() then
		WoWClaude.reloadAfterCombat = true
		if ui.status then
			ui.status:SetText("In combat - will reload as soon as it ends")
		end
		return
	end
	ReloadUI()
end

-- ReloadUI() only works from a hardware event (a keypress or click), never from
-- a timer. So the automatic reload piggybacks on the player's own next keypress
-- once the interval has elapsed. The key still reaches the game normally.
local keyCatcher = CreateFrame("Frame", "WoWClaudeKeyCatcher", UIParent)
keyCatcher:Hide()
keyCatcher:EnableKeyboard(true)
keyCatcher:SetScript("OnKeyDown", function(self, key)
	if db and AnyPending() and db.settings.autoRefresh
		and GetTime() >= (WoWClaude.nextAutoRefresh or 0)
		and not InCombatLockdown() then
		self:Hide()
		ReloadUI()
	end
end)

-- Arm the keypress reload. In pixel mode this is only used once the slot pool
-- is exhausted (a reload frees every slot) or the slots are not installed.
function WoWClaude.ArmAutoRefresh()
	keyCatcher:Hide()
	if not AnyPending() or not db.settings.autoRefresh then return end
	if db.settings.mode == "pixel" and not (run.slotsExhausted or run.slotsMissing or run.pixelFailed) then return end
	-- Propagation can't be changed in combat. Never show the catcher without it,
	-- or it would eat every keypress. PLAYER_REGEN_ENABLED re-arms after combat.
	if not keyCatcher.propagates then
		if InCombatLockdown() or not keyCatcher.SetPropagateKeyboardInput then return end
		keyCatcher:SetPropagateKeyboardInput(true)
		keyCatcher.propagates = true
	end
	WoWClaude.nextAutoRefresh = GetTime() + db.settings.interval
	keyCatcher:Show()
end

---------------------------------------------------------------------------
-- Pixel strip (out)
---------------------------------------------------------------------------

local strip
local cellPool = {}

local function EnsureStrip()
	if strip then return strip end
	strip = CreateFrame("Frame", "WoWClaudeStrip", UIParent)
	strip:SetFrameStrata("TOOLTIP")
	strip:SetFrameLevel(10000)
	-- Scale so that one UI unit is exactly one physical pixel (see Blizzard's PixelUtil).
	local physH = 1080
	if GetPhysicalScreenSize then
		local _, h = GetPhysicalScreenSize()
		physH = h or physH
	end
	if strip.SetIgnoreParentScale then strip:SetIgnoreParentScale(true) end
	strip:SetScale(768 / physH)
	strip:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	strip:SetSize(CELLS_PER_ROW * CELL, MAX_ROWS * CELL)
	strip:Hide()
	return strip
end

local function HideStrip()
	if strip then strip:Hide() end
	run.stripShown = nil
end

local function ShowStrip(id, payload)
	local cells = Codec.Encode(id % 65536, payload)
	local s = EnsureStrip()
	local rows = math.ceil(#cells / CELLS_PER_ROW)
	local total = rows * CELLS_PER_ROW
	for i = 1, total do
		local t = cellPool[i]
		if not t then
			t = s:CreateTexture(nil, "OVERLAY")
			t:SetSize(CELL, CELL)
			local c = (i - 1) % CELLS_PER_ROW
			local r = math.floor((i - 1) / CELLS_PER_ROW)
			t:SetPoint("TOPLEFT", s, "TOPLEFT", c * CELL, -r * CELL)
			cellPool[i] = t
		end
		local cr, cg, cb = Codec.CellColor(cells[i] or 0)
		t:SetColorTexture(cr, cg, cb, 1)
		t:Show()
	end
	for i = total + 1, #cellPool do
		cellPool[i]:Hide()
	end
	s:Show()
	run.stripShown = true
end

-- Record: session, chat, id, cwd, flags, name, text. Several records per frame.
local function RecordFor(id, rec)
	local name = (rec.name or ""):gsub("[\30\31]", " ")
	return table.concat({ db.session, rec.chat, tostring(id), rec.cwd, rec.flags or "", name, rec.text }, US)
end

-- Redraw the strip from every outbound message the bridge hasn't acknowledged.
local function RefreshStrip()
	local ids = {}
	for id, rec in pairs(run.outbound) do
		if not rec.acked then table.insert(ids, id) end
	end
	if #ids == 0 then
		HideStrip()
		return
	end
	table.sort(ids)
	-- Newest first; drop the oldest if the frame would overflow.
	local parts, size, latest = {}, 0, ids[#ids]
	for i = #ids, 1, -1 do
		local r = RecordFor(ids[i], run.outbound[ids[i]])
		if size + #r + 1 > Codec.MAX_PAYLOAD then break end
		table.insert(parts, 1, r)
		size = size + #r + 1
	end
	ShowStrip(latest, table.concat(parts, RS))
end

---------------------------------------------------------------------------
-- Signals and slots (in)
---------------------------------------------------------------------------

-- Optional cheap poll: an empty .wav won't play, a valid one will. The bridge
-- fills sig/NNN.wav when reply NNN is ready. Self-disables if it misbehaves.
local signalAvailable = type(PlaySoundFile) == "function"
local signalStats = { checks = 0, hits = 0, lastHit = nil }

local function SoundValid(path)
	if not signalAvailable or not db.settings.signal then return false end
	signalStats.checks = signalStats.checks + 1
	local ok, willPlay, handle = pcall(PlaySoundFile, path, "Master")
	if not ok then
		signalAvailable = false
		signalStats.error = tostring(willPlay)
		return false
	end
	if willPlay and handle then pcall(StopSound, handle) end
	if willPlay then
		signalStats.hits = signalStats.hits + 1
		signalStats.lastHit = GetTime()
	end
	return willPlay and true or false
end

local function CheckSignal(kind, id)
	if run.signalUnreliable then return false end
	return SoundValid(string.format("Interface\\AddOns\\WoWClaude\\%s\\%03d.wav", kind, SlotNumber(id)))
end

-- Heartbeat: the bridge flips act/NNN/kk.wav for the k-th action of message NNN.
local function ActPath(id, k)
	return string.format("Interface\\AddOns\\WoWClaude\\act\\%03d\\%02d.wav", SlotNumber(id), k)
end

local function StartActivity(chat, id)
	local a = { next = 1, count = 0, startedAt = GetTime() }
	-- The bridge can't have written anything yet, so a valid first file means the
	-- client cached this slot number's files from an earlier use: don't trust them.
	if SoundValid(ActPath(id, 1)) then a.unreliable = true end
	run.act = run.act or {}
	run.act[chat.id] = a
end

-- Returns true if the counter moved.
local function PollActivity(chat)
	local a = run.act and run.act[chat.id]
	if not a or a.unreliable or not chat.pendingId then return false end
	local moved = false
	for _ = 1, 3 do
		if a.next > ACT_MAX then break end
		if not SoundValid(ActPath(chat.pendingId, a.next)) then break end
		a.count = a.count + 1
		a.next = a.next + 1
		a.last = GetTime()
		moved = true
	end
	return moved
end

-- Bridge presence. Evidence the bridge is alive comes from several places:
-- presence beats, acks, slot data (which carries the bridge's clock), replies.
local function NotedBridge(at)
	at = at or GetTime()
	if not run.bridgeSeen or at > run.bridgeSeen then run.bridgeSeen = at end
	run.pixelFailed = nil
end

local function PresencePath(k)
	return string.format("Interface\\AddOns\\WoWClaude\\presence\\%04d.wav", k)
end

-- Valid presence files form a prefix 1..k, so a binary search finds the head.
local function FindPresenceHead()
	local lo, hi = 0, PRESENCE_MAX
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if SoundValid(PresencePath(mid)) then lo = mid else hi = mid - 1 end
	end
	return lo
end

local function PollPresence()
	if not signalAvailable or not db.settings.signal then return end
	run.presence = run.presence or { last = FindPresenceHead() }
	local p = run.presence
	for _ = 1, 3 do
		local k = (p.last % PRESENCE_MAX) + 1
		if not SoundValid(PresencePath(k)) then break end
		p.last = k
		p.beats = (p.beats or 0) + 1
		NotedBridge()
	end
end

-- Whether the 30-second presence beats can reach us at all. When they can't
-- (self-test failed, or signal checks turned off), the only evidence of the
-- bridge is a slot read: the idle poll below and the replies themselves.
local function PresenceWorks()
	return signalAvailable and db ~= nil and db.settings.signal
end

-- Returns state ("ok" | "stale" | "down" | "unknown"), a color and a description.
-- With presence beats the bridge is heard from every 30 s, so 90 s of silence is
-- suspicious. Without them the addon only hears from it every IDLE_POLL_SECONDS,
-- so the windows have to be wider or the light could never stay green between
-- messages and every reply would be followed by a Reconnect.
function WoWClaude.BridgeState()
	local seen = run.bridgeSeen
	if not seen then
		return "unknown", 0.6, 0.6, 0.6, "Bridge: not seen yet this session"
	end
	local age = GetTime() - seen
	local okFor, staleFor = 90, 300
	if not PresenceWorks() then
		okFor, staleFor = IDLE_POLL_SECONDS + 120, IDLE_POLL_SECONDS * 2 + 120
	end
	if age < okFor then
		return "ok", 0.2, 0.9, 0.3, "Bridge: connected (seen " .. FmtDur(age) .. " ago)"
	elseif age < staleFor then
		return "stale", 0.95, 0.8, 0.2, "Bridge: last seen " .. FmtDur(age) .. " ago"
	end
	return "down", 0.9, 0.25, 0.25, "Bridge: not seen for " .. FmtDur(age) .. " - is the bridge running?"
end

-- Same icons the friends list uses for online / away / busy / offline.
local STATE_ICON = {
	ok = "Interface\\FriendsFrame\\StatusIcon-Online",
	stale = "Interface\\FriendsFrame\\StatusIcon-Away",
	down = "Interface\\FriendsFrame\\StatusIcon-DnD",
	unknown = "Interface\\FriendsFrame\\StatusIcon-Offline",
}

function WoWClaude.UpdateDot()
	local state, _, _, _, tip = WoWClaude.BridgeState()
	if run.pixelFailed then state = "down" end
	if not signalAvailable and signalStats.selftest then
		tip = tip .. "\n(sound-file channel unavailable: " .. signalStats.selftest .. "; using slot checks only)"
	end
	for _, dot in ipairs({ ui.dot, ui.miniDot }) do
		if dot then
			dot:SetTexture(STATE_ICON[state] or STATE_ICON.unknown)
			dot.tip = tip
		end
	end
end

-- Connected = the bridge has been seen recently. In pixel mode, sending needs this;
-- until then the Connect button takes the Send button's place. The reload
-- transport has no idea whether the bridge is there, so it never gates.
function WoWClaude.IsConnected()
	if not db or db.settings.mode ~= "pixel" then return true end
	return WoWClaude.BridgeState() == "ok" and not run.pixelFailed
end

-- Connect button: say hello to the bridge (it acks, refreshes the slots and
-- offers a restore), ignoring SayHello's throttle so a click always does something.
function WoWClaude.Connect()
	if db.settings.mode ~= "pixel" then
		SafeReload()
		return
	end
	run.lastHelloAt = nil
	run.pixelFailed = nil
	run.connectFailed = nil
	run.connectingAt = GetTime()
	WoWClaude.SayHello()
end

-- One word for the connection state, so Tick can tell when it changed.
local function ConnectionKey()
	if WoWClaude.IsConnected() then return "ok" end
	if run.connectingAt then return "connecting" end
	if run.connectFailed then return "failed" end
	return WoWClaude.BridgeState()
end

-- Called every tick: time out a Connect attempt, and redraw when the state flips
-- (light, button, status line, placeholder) without redrawing every tick.
function WoWClaude.CheckConnection()
	if run.connectingAt then
		if WoWClaude.IsConnected() then
			run.connectingAt, run.connectFailed = nil, nil
			-- A message typed while disconnected goes out now, without a second click,
			-- as long as the same chat is still in front and free.
			local queued = run.sendOnConnect
			run.sendOnConnect = nil
			local c = queued and ActiveChat()
			if c and c.id == queued.chat and not c.pendingId then
				if ui.input and Trim(ui.input:GetText() or "") == queued.text then ui.input:SetText("") end
				WoWClaude.Send(queued.text, queued.allow)
			end
		elseif GetTime() - run.connectingAt > CONNECT_WAIT then
			run.connectingAt, run.connectFailed = nil, true
			run.sendOnConnect = nil -- the text is still in the box
		end
	elseif run.connectFailed and WoWClaude.IsConnected() then
		run.connectFailed = nil
	end
	local key = ConnectionKey()
	if key ~= run.connKey then
		run.connKey = key
		WoWClaude.Render()
	end
end

-- Swap Send and Connect depending on the state; part of UpdateStatus.
function WoWClaude.UpdateConnect()
	if not ui.connect or not ui.send then return end
	local connected = WoWClaude.IsConnected()
	ui.send:SetShown(connected)
	ui.connect:SetShown(not connected)
	if connected then return end
	if run.connectingAt then
		ui.connect:SetText("Connecting...")
		ui.connect:Disable()
	else
		ui.connect:SetText(WoWClaude.BridgeState() == "stale" and "Reconnect" or "Connect")
		ui.connect:Enable()
	end
end

-- Prove the sound-file trick actually distinguishes empty from valid files on this
-- client before trusting it for presence, heartbeats and readiness signals.
local function SelfTestSignals()
	if not signalAvailable then
		signalStats.selftest = "PlaySoundFile missing"
		return
	end
	local emptyLooksValid = SoundValid("Interface\\AddOns\\WoWClaude\\ctl\\empty.wav")
	local validLooksValid = SoundValid("Interface\\AddOns\\WoWClaude\\ctl\\valid.wav")
	if emptyLooksValid then
		signalAvailable = false
		signalStats.selftest = "an empty file reports as playable"
	elseif not validLooksValid then
		signalAvailable = false
		signalStats.selftest = "a valid file reports as unplayable (files not indexed? restart WoW)"
	else
		signalStats.selftest = "passed"
	end
end

local function ActivityLine(chat)
	local a = run.act and run.act[chat.id]
	local now = GetTime()
	local started = (a and a.startedAt) or run.sentAt or now
	local s = "running " .. FmtDur(now - started)
	if a and not a.unreliable then
		s = s .. " - " .. a.count .. (a.count == 1 and " action" or " actions")
		if a.last then
			local quiet = now - a.last
			s = s .. ", last " .. FmtDur(quiet) .. " ago"
			if quiet > 120 then s = s .. " (quiet for a while - stuck? /wow-claude cancel)" end
		elseif now - started > 60 then
			s = s .. ", no activity seen yet"
		end
	end
	return s
end

local function FreeSlot()
	for i = 1, SLOT_COUNT do
		local name = SlotName(i)
		if not C_AddOns.IsAddOnLoaded(name) then
			return name
		end
	end
end

local function ScheduleNextPoll()
	local idx = (run.polls or 0) + 1
	local t = POLL_SCHEDULE[idx]
	if not t then
		t = POLL_SCHEDULE[#POLL_SCHEDULE] + POLL_TAIL * (idx - #POLL_SCHEDULE)
	end
	run.nextPollAt = (run.sentAt or GetTime()) + t
end

local Finish -- defined below

local function MarkAcked(id)
	local rec = run.outbound[id]
	if rec and not rec.acked then
		rec.acked = true
		RefreshStrip()
	end
	NotedBridge()
end

-- Dispatch a list of reply records to the chats waiting for them.
local function ApplyReplies(replies)
	local matched = false
	for _, r in ipairs(replies or {}) do
		local c = FindChat(r.chat)
		if c and c.pendingId and r.id == c.pendingId then
			matched = true
			MarkAcked(r.id)
			local denied = type(r.denied) == "table" and #r.denied > 0 and r.denied or nil
			if r.status == "done" then
				Finish(c, "claude", r.text or "", denied)
			elseif r.status == "error" then
				Finish(c, "system", "Bridge error: " .. tostring(r.text), denied)
			elseif r.status == "working" then
				c.progress = r.text
			end
		end
	end
	return matched
end

-- The bridge keeps every chat's transcript. After the client wipes our saved data,
-- it sends them back once, addressed to our new session token.
local function ImportRestore(r)
	if type(r) ~= "table" or r.token ~= db.session or db.restored then return end
	db.restored = true
	local added = 0
	local current = ActiveChat()
	for _, rc in ipairs(r.chats or {}) do
		-- Skip chats deleted here that the bridge hasn't been told about yet.
		if type(rc) == "table" and rc.id and not FindChat(rc.id) and not db.forget[rc.id] and #db.chats < MAX_CHATS then
			local chat = {
				id = rc.id,
				name = (rc.name and rc.name ~= "") and rc.name or ("Chat " .. (#db.chats + 1)),
				cwd = rc.cwd or DEFAULT_CWD,
				history = {},
				unread = 0,
				created = time(),
			}
			for _, m in ipairs(rc.messages or {}) do
				table.insert(chat.history, { role = m.role, text = m.text, id = m.id, t = m.t })
			end
			-- Keep the chat we're currently using last so it stays where it was.
			table.insert(db.chats, math.max(1, #db.chats), chat)
			added = added + 1
		end
	end
	run.restoring = nil
	if added > 0 then
		if current and #current.history <= 2 then
			for _, ch in ipairs(db.chats) do
				if ch ~= current and ch.name == current.name then current.name = "New chat" end
			end
		end
		AddHistory(current, "system", "Restored " .. added .. " chat(s) from the bridge after the game reset the saved data.")
		WoWClaude.RenderChatList()
	end
end

local function TryLoadSlot(why)
	local name = FreeSlot()
	if not name then
		run.slotsExhausted = true
		WoWClaude.ArmAutoRefresh()
		WoWClaude.UpdateStatus()
		return
	end
	WoWClaude_SlotData = nil
	local loaded, reason = C_AddOns.LoadAddOn(name)
	if not loaded then
		run.slotError = reason
		if reason == "MISSING" or reason == "DISABLED" then
			run.slotsMissing = true
			WoWClaude.ArmAutoRefresh()
		end
		WoWClaude.UpdateStatus()
		return
	end
	run.polls = (run.polls or 0) + 1
	ScheduleNextPoll()
	local data = WoWClaude_SlotData
	if type(data) == "table" and type(data.now) == "number" then
		-- The bridge's clock and ours are the same machine; translate to GetTime().
		NotedBridge(GetTime() - (time() - data.now))
	end
	if type(data) == "table" and type(data.cwd) == "string" and data.cwd ~= "" then run.bridgeCwd = data.cwd end
	local matched = ApplyReplies(type(data) == "table" and data.replies or nil)
	if type(data) == "table" and data.restore then ImportRestore(data.restore) end
	if why == "signal" and not matched then
		run.signalUnreliable = true
	end
	WoWClaude.Render()
end

local function Tick()
	if not db then return end
	local now = GetTime()
	PollPresence()
	-- Without presence beats, the only evidence is a slot read; spend one every
	-- IDLE_POLL_SECONDS while idle so the light still reflects reality (and stays
	-- green while the bridge is up: BridgeState allows for this interval).
	if not PresenceWorks() and db.settings.mode == "pixel" and not AnyPending()
		and now - (run.lastIdlePoll or -1e9) >= IDLE_POLL_SECONDS then
		run.lastIdlePoll = now
		TryLoadSlot("idle")
	end
	WoWClaude.UpdateDot()
	WoWClaude.CheckConnection()
	if db.settings.mode ~= "pixel" then return end
	local changed = false
	if run.helloPollAt and now >= run.helloPollAt then
		run.helloPollAt = nil
		TryLoadSlot("hello")
		-- Whatever that slot held, the wait is over.
		if run.restoring then
			run.restoring = nil
			WoWClaude.Render()
		end
	end
	if run.restoring and now - run.restoring > 25 then
		run.restoring = nil
		WoWClaude.Render()
	end
	for id, rec in pairs(run.outbound) do
		if not rec.acked and CheckSignal("ack", id) then
			rec.acked = true
			changed = true
			NotedBridge()
		end
		-- A hello only needs the bridge to have been seen; it never escalates.
		-- A forget is the same, but the bridge must have been seen a moment after
		-- the record went up, so it had a chance to read it.
		if (rec.hello or rec.forget) and not rec.acked and run.bridgeSeen and run.bridgeSeen >= rec.sentAt + (rec.forget and 2 or 0) then
			rec.acked = true
			changed = true
		end
		if rec.acked then
			if rec.forget then db.forget[rec.forget] = nil end
			run.outbound[id] = nil
			changed = true
		elseif rec.hello and now - rec.sentAt >= 20 then
			run.outbound[id] = nil
			changed = true
		elseif now - rec.sentAt >= STRIP_SECONDS then
			rec.tries = (rec.tries or 1) + 1
			if rec.tries <= STRIP_TRIES then
				-- Nobody picked it up: show it again.
				rec.sentAt = now
				changed = true
			elseif rec.forget then
				-- The bridge is away; db.forget keeps it for the next hello.
				run.outbound[id] = nil
				changed = true
			else
				-- Give up on pixels for this message; the reload path still has it.
				run.outbound[id] = nil
				run.pixelFailed = true
				changed = true
				WoWClaude.ArmAutoRefresh()
			end
		end
	end
	if changed then
		RefreshStrip()
		WoWClaude.UpdateStatus()
	end
	if not AnyPending() then return end
	local moved = false
	for _, c in ipairs(db.chats) do
		if c.pendingId and PollActivity(c) then moved = true end
	end
	if moved then WoWClaude.Render() end
	for _, c in ipairs(db.chats) do
		if c.pendingId and CheckSignal("sig", c.pendingId) then
			TryLoadSlot("signal")
			return
		end
	end
	if run.nextPollAt and now >= run.nextPollAt then
		TryLoadSlot("schedule")
	end
end

-- Pull whatever bridge.js last wrote into Inbox.lua (the reload path).
local function ProcessInbox()
	local inbox = WoWClaude_Inbox
	if type(inbox) ~= "table" then return end
	if type(inbox.cwd) == "string" and inbox.cwd ~= "" then run.bridgeCwd = inbox.cwd end
	ApplyReplies(inbox.replies)
	if inbox.restore then ImportRestore(inbox.restore) end
end

Finish = function(chat, role, text, denied)
	AddHistory(chat, role, text, chat.pendingId, denied)
	chat.pendingId = nil
	chat.progress = nil
	if run.act then run.act[chat.id] = nil end
	NotedBridge()
	local visible = ui.frame and ui.frame:IsShown() and db.activeChat == chat.id
	if not visible then
		chat.unread = (chat.unread or 0) + 1
	end
	if not AnyPending() then
		keyCatcher:Hide()
	end
	if visible and ui.input and chat.draft and chat.draft ~= "" then
		ui.input:SetText(chat.draft)
		chat.draft = nil
	end
	WoWClaude.Render()
	WoWClaude.Notify(chat, text)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- allow: optional list of permission rules to grant before this message runs.
function WoWClaude.Send(text, allow)
	local c = ActiveChat()
	if not c then return end
	text = Trim(text or "")
	if c.pendingId then
		-- Typing while waiting: keep the draft, and check for the reply.
		if text ~= "" then c.draft = text end
		if db.settings.mode == "pixel" and not (run.slotsExhausted or run.slotsMissing) then
			TryLoadSlot("manual")
		else
			SafeReload()
		end
		return
	end
	if text == "" then return end
	if not WoWClaude.IsConnected() then
		-- Not connected: the message stays in the box and we try to connect;
		-- CheckConnection sends it the moment the light turns green. If the bridge
		-- never answers, the text is still in the box for a later try.
		if ui.input then ui.input:SetText(text) end
		run.sendOnConnect = { chat = c.id, text = text, allow = allow }
		if not run.connectingAt then WoWClaude.Connect() end
		WoWClaude.Toggle(true)
		return
	end
	local limit = Codec.MAX_PAYLOAD - 300
	if #text > limit then
		AddHistory(c, "system", "That message is too long for one send (" .. #text .. " chars, max ~" .. limit .. "). Split it up.")
		WoWClaude.Render()
		return
	end

	db.lastSeq = db.lastSeq + 1
	local id = db.lastSeq
	local tokens = {}
	if c.resetNext then table.insert(tokens, "n") end
	if allow and #allow > 0 then table.insert(tokens, "allow=" .. table.concat(allow, ",")) end
	local flags = table.concat(tokens, ";")
	local newSession = c.resetNext and true or nil
	c.resetNext = nil
	db.outbox = {
		id = id,
		session = db.session,
		chat = c.id,
		text = ToHex(text),
		cwd = ToHex(c.cwd),
		newSession = newSession,
		t = time(),
	}
	c.pendingId = id
	c.draft = nil
	c.progress = nil
	AddHistory(c, "user", text, id)
	-- A chat still carrying its default name takes its title from the first message
	-- you send (system notes like "/wow-claude cd" before it don't count).
	if c.name:match("^Chat %d+$") then
		local first = true
		for _, m in ipairs(c.history) do
			if m.role == "user" and m.id ~= id then first = false break end
		end
		if first then c.name = AutoTitle(text) or c.name end
	end
	db.settings.shown = true

	if db.settings.mode == "pixel" then
		run.outbound[id] = { chat = c.id, cwd = c.cwd, flags = flags, name = c.name, text = text, sentAt = GetTime() }
		run.sentAt = GetTime()
		run.polls = 0
		StartActivity(c, id)
		ScheduleNextPoll()
		RefreshStrip()
		WoWClaude.Render()
	else
		SafeReload()
	end
end

-- Forget: a record with no text telling the bridge a chat was deleted, so it drops
-- the transcript (which a later restore would otherwise bring back) and the
-- Claude session. db.forget keeps the id until the bridge acks, so a delete made
-- while the bridge was away is sent again with the next hello.
local function SendForget(chatId)
	if db.settings.mode ~= "pixel" then return end
	for _, rec in pairs(run.outbound) do
		if rec.forget == chatId and not rec.acked then return end
	end
	local info = db.forget[chatId] or {}
	db.lastSeq = db.lastSeq + 1
	run.outbound[db.lastSeq] = { chat = chatId, cwd = info.cwd or "", flags = "d", name = info.name or "", text = "", sentAt = GetTime(), forget = chatId }
	RefreshStrip()
end

local function ForgetOnBridge(c)
	if not c or not c.id then return end
	db.forget[c.id] = { name = c.name, cwd = c.cwd }
	SendForget(c.id)
end

-- Hello: a record with no text that just announces our session token. The bridge
-- acks it, offers a restore if our saved data is fresh, and refreshes the slots,
-- so the status light and any lost chats come back before the first message.
function WoWClaude.SayHello()
	if db.settings.mode ~= "pixel" then return end
	local now = GetTime()
	if run.lastHelloAt and now - run.lastHelloAt < 60 then return end
	run.lastHelloAt = now
	db.lastSeq = db.lastSeq + 1
	local c = ActiveChat()
	run.outbound[db.lastSeq] = { chat = c and c.id or "", cwd = c and c.cwd or "", flags = "h", name = c and c.name or "", text = "", sentAt = now, hello = true }
	run.helloPollAt = now + 5
	-- Deletions the bridge never confirmed ride along with the hello.
	for id in pairs(db.forget) do SendForget(id) end
	-- Fresh saved data: show "restoring" instead of an empty panel until we hear back.
	if not db.restored then
		local empty = true
		for _, ch in ipairs(db.chats) do
			if #ch.history > 0 then empty = false end
		end
		if empty then run.restoring = now end
	end
	RefreshStrip()
	WoWClaude.Render()
end

-- Put the active chat's pending message back on the strip.
function WoWClaude.Resend()
	local c = ActiveChat()
	if not c or not c.pendingId then return end
	local text
	for i = #c.history, 1, -1 do
		if c.history[i].id == c.pendingId and c.history[i].role == "user" then
			text = c.history[i].text
			break
		end
	end
	if not text then return end
	run.outbound[c.pendingId] = { chat = c.id, cwd = c.cwd, flags = "", name = c.name, text = text, sentAt = GetTime() }
	run.sentAt = GetTime()
	run.polls = 0
	ScheduleNextPoll()
	RefreshStrip()
	WoWClaude.UpdateStatus()
end

function WoWClaude.SendFromInput()
	if not ui.input then return end
	local text = ui.input:GetText()
	ui.input:SetText("")
	ui.input:ClearFocus() -- hand the keyboard back to the game after sending
	WoWClaude.Send(text)
end

-- The Allow button: grant the rules a reply asked for, then tell Claude to carry on.
function WoWClaude.Allow(chatId, rules)
	local c = FindChat(chatId)
	if not c or c.pendingId or not rules or #rules == 0 then return end
	if db.activeChat ~= c.id then WoWClaude.SwitchChat(c.id) end
	for _, m in ipairs(c.history) do m.denied = nil end
	AddHistory(c, "system", "Allowed: " .. table.concat(rules, ", "))
	WoWClaude.Send("Those actions are allowed now. Continue from where you left off.", rules)
end

---------------------------------------------------------------------------
-- Chats
---------------------------------------------------------------------------

function WoWClaude.SwitchChat(id)
	local c = FindChat(id)
	if not c then return end
	local prev = ActiveChat()
	if prev and prev ~= c and ui.input then
		local typed = Trim(ui.input:GetText() or "")
		prev.draft = typed ~= "" and typed or nil
	end
	db.activeChat = c.id
	c.unread = 0
	if ui.input then
		ui.input:SetText(c.draft or "")
		c.draft = nil
	end
	WoWClaude.Render()
	WoWClaude.RenderChatList()
end

function WoWClaude.NewChat(name)
	local c = AddChat(name and name ~= "" and name or nil)
	if not c then
		local a = ActiveChat()
		AddHistory(a, "system", "Chat limit reached (" .. MAX_CHATS .. "). Delete one first with /wow-claude delete.")
		WoWClaude.Render()
		return
	end
	WoWClaude.SwitchChat(c.id)
	WoWClaude.Toggle(true)
end

-- Folder this chat's Claude works in. Empty (or "-" / "default") = the bridge's
-- default. Relative paths are resolved by the bridge against that default.
function WoWClaude.SetFolder(rest, c)
	c = c or ActiveChat()
	if not c then return end
	rest = Trim(rest or "")
	if rest == "-" or rest == "default" then rest = "" end
	local base = run.bridgeCwd or "the bridge's default folder"
	if rest ~= "" then
		local changed = rest ~= c.cwd
		c.cwd = rest
		local absolute = rest:match("^%a:[\\/]") or rest:match("^[\\/~]")
		local note = absolute and "" or (" (relative to " .. base .. ")")
		AddHistory(c, "system", "cwd set to " .. rest .. note .. (changed and #c.history > 1 and "; the next message starts a fresh Claude session there" or ""))
	elseif c.cwd ~= "" then
		c.cwd = ""
		AddHistory(c, "system", "cwd reset to the bridge's default: " .. base)
	else
		AddHistory(c, "system", "cwd is the bridge's default: " .. base .. " (/wow-claude cd <folder>, or right-click the chat and pick Folder, to change)")
	end
	WoWClaude.Render()
end

StaticPopupDialogs["WOWCLAUDE_FOLDER"] = {
	text = "Folder for this chat\n\nRelative to the bridge's folder (%s), ~, or a full path.\nEmpty = the bridge's default. Changing it starts a fresh Claude session.",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	editBoxWidth = 320,
	maxLetters = 250,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.cwd or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		if chat and box then WoWClaude.SetFolder(box:GetText(), chat) end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWCLAUDE_FOLDER"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Folder dialog for a chat (the active one when no id is given).
function WoWClaude.FolderPrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWCLAUDE_FOLDER", run.bridgeCwd or "unknown until connected", nil, { id = c.id, cwd = c.cwd })
end

StaticPopupDialogs["WOWCLAUDE_RENAME"] = {
	text = "Rename this chat",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 24,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.name or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		local name = box and Trim(box:GetText() or "") or ""
		if chat and name ~= "" then
			chat.name = name:sub(1, 24)
			WoWClaude.Render()
		end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWCLAUDE_RENAME"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Rename dialog for a chat (the active one when no id is given).
function WoWClaude.RenamePrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWCLAUDE_RENAME", nil, nil, { id = c.id, name = c.name })
end
WoWClaude.RenameActive = WoWClaude.RenamePrompt

-- Delete a chat (the active one when no id is given). The last chat is cleared
-- and renamed instead of removed, so there is always one to type into. Either
-- way the bridge is told to forget it, so a restore won't bring it back.
function WoWClaude.DeleteChat(id)
	local c, idx = nil, nil
	if id then c, idx = FindChat(id) end
	if not c then c, idx = ActiveChat() end
	if not c then return end
	ForgetOnBridge(c)
	if #db.chats == 1 then
		wipe(c.history)
		c.pendingId, c.progress, c.unread, c.draft = nil, nil, 0, nil
		c.name = "Chat 1"
		WoWClaude.Render()
		WoWClaude.RenderChatList()
		return
	end
	table.remove(db.chats, idx)
	if db.activeChat == c.id then
		WoWClaude.SwitchChat(db.chats[math.min(idx, #db.chats)].id)
	else
		WoWClaude.RenderChatList()
	end
end

-- The trash can on a chat row asks first; /wow-claude delete does not.
StaticPopupDialogs["WOWCLAUDE_DELETE"] = {
	text = "Delete chat \"%s\"?\n\nIts transcript goes away (the last chat is cleared instead of removed).",
	button1 = OKAY,
	button2 = CANCEL,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnAccept = function(dialog, data)
		if data then WoWClaude.DeleteChat(data.id) end
	end,
}

function WoWClaude.ConfirmDelete(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWCLAUDE_DELETE", Display(c.name), nil, { id = c.id })
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function WoWClaude.UpdateStatus()
	if not ui.status then return end
	local c = ActiveChat()
	local mode = db.settings.mode
	local s
	if c and c.pendingId then
		local id = c.pendingId
		local elapsed = run.sentAt and (GetTime() - run.sentAt) or 0
		local rec = run.outbound[id]
		if mode == "pixel" then
			if run.slotsMissing then
				s = "Reply slots not installed (run install-slots.js, restart WoW). Using reload instead: Enter or Refresh"
			elseif run.slotsExhausted then
				s = "Slot pool used up this session - next keypress reloads to free it"
			elseif run.pixelFailed then
				s = "Bridge didn't see #" .. id .. " after " .. STRIP_TRIES .. " tries - next keypress switches to the reload path (or /wow-claude reload)"
			elseif c.progress or (run.act and run.act[c.id] and run.act[c.id].count > 0) then
				s = "Claude is working on #" .. id .. " - " .. ActivityLine(c)
			elseif rec and not rec.acked then
				s = "Sending #" .. id .. (rec.tries and rec.tries > 1 and (" (try " .. rec.tries .. "/" .. STRIP_TRIES .. ")") or "") .. "..."
				local state = WoWClaude.BridgeState()
				if state == "down" then s = s .. " - bridge not seen lately, is the bridge running?" end
			else
				s = "Waiting for #" .. id .. " (checked " .. (run.polls or 0) .. "x)"
				if elapsed > 45 then
					s = s .. " - no sign of the bridge. Is the bridge running? /wow-claude resend"
				end
			end
		else
			s = "Waiting for reply #" .. id .. ". Enter or Refresh checks now"
			if db.settings.autoRefresh then
				s = s .. "; auto on next keypress after " .. db.settings.interval .. "s"
			end
		end
	elseif not WoWClaude.IsConnected() then
		if run.connectingAt and run.sendOnConnect then
			s = "Connecting to the bridge... your message goes out as soon as it answers"
		elseif run.connectingAt then
			s = "Connecting to the bridge..."
		elseif run.connectFailed then
			s = "No answer from the bridge. Is it running (npm start)? Connect tries again"
		elseif WoWClaude.BridgeState() == "stale" then
			s = "Bridge not seen for a while - click Reconnect"
		else
			s = "Not connected - start the bridge, then click Connect"
		end
	elseif c and c.draft and c.draft ~= "" then
		s = "Reply arrived. Your draft is back in the box - Enter to send it"
	elseif run.restoring then
		s = "Connecting to the bridge..."
	else
		s = "Ready"
	end
	ui.status:SetText(s)
	run.statusText = s
	WoWClaude.UpdateDot()
	WoWClaude.UpdateConnect()
	if ui.title then
		local t = c and Display(c.name) or "Claude"
		local folder = FolderName(ChatFolder(c))
		if folder ~= "" then t = t .. "  |cff888888" .. Display(folder) .. "|r" end
		ui.title:SetText(t)
	end
	local cwdText
	if c and c.cwd ~= "" then
		cwdText = Display(c.cwd)
	elseif run.bridgeCwd then
		cwdText = Display(run.bridgeCwd) .. " (bridge default)"
	else
		cwdText = "(bridge default - start the bridge in a folder, or right-click the chat and pick Folder)"
	end
	ui.cwd:SetText("cwd: " .. cwdText .. "   mode: " .. mode)
	if ui.resend then ui.resend:SetShown(c and c.pendingId ~= nil and mode == "pixel") end
	if ui.refresh then ui.refresh:SetShown(mode ~= "pixel" or run.slotsExhausted or run.slotsMissing or run.pixelFailed or false) end
	WoWClaude.UpdateMini()
end

-- One message bubble: accent bar, colored label, timestamp, wrapped body.
local function GetBubble(i)
	local b = ui.bubbles[i]
	if b then return b end
	b = CreateFrame("Frame", nil, ui.content)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.accent = b:CreateTexture(nil, "BORDER")
	b.accent:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b.accent:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
	b.accent:SetWidth(3)
	b.who = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.who:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -6)
	b.who:SetJustifyH("LEFT")
	b.when = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.when:SetPoint("TOPRIGHT", b, "TOPRIGHT", -8, -6)
	b.body = b:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	b.body:SetPoint("TOPLEFT", b.who, "BOTTOMLEFT", 0, -4)
	b.body:SetJustifyH("LEFT")
	b.body:SetJustifyV("TOP")
	b.body:SetWordWrap(true)
	b.body:SetNonSpaceWrap(true)
	b.allow = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
	b.allow:SetHeight(22)
	b.allow:SetPoint("TOPLEFT", b.body, "BOTTOMLEFT", 0, -6)
	b.allow:SetScript("OnClick", function(self)
		WoWClaude.Allow(self.chatId, self.rules)
	end)
	b.allow:Hide()
	-- FontStrings can't be selected, so a click opens the message in the copy box.
	b:EnableMouse(true)
	b:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and self.text and self.text ~= "" then WoWClaude.ShowCopy(self.text) end
	end)
	ui.bubbles[i] = b
	return b
end

function WoWClaude.Render()
	local c = ActiveChat()
	if ui.content and c then
		local width = ui.scroll:GetWidth()
		if not width or width < 80 then width = 400 end
		ui.content:SetWidth(width)
		local y, n = 0, 0
		local function Place(role, text, when, dim, denied)
			n = n + 1
			local b = GetBubble(n)
			local st = ROLE_STYLE[role] or ROLE_STYLE.system
			b:SetWidth(width)
			b.bg:SetColorTexture(st.bg[1], st.bg[2], st.bg[3], st.bg[4])
			b.accent:SetColorTexture(st.color[1], st.color[2], st.color[3], 0.9)
			b.who:SetText(st.label)
			b.who:SetTextColor(st.color[1], st.color[2], st.color[3])
			b.when:SetText(when or "")
			b.body:SetWidth(width - 18)
			b.body:SetText(Display(text))
			if dim then
				b.body:SetTextColor(0.72, 0.72, 0.72)
			else
				b.body:SetTextColor(0.93, 0.93, 0.93)
			end
			local h = b.body:GetStringHeight()
			if not h or h < 1 then h = 14 end
			local extra = 0
			if denied then
				local label = "Allow " .. table.concat(denied, ", ") .. " & retry"
				b.allow:SetText(label)
				b.allow:SetWidth(math.min(width - 24, math.max(160, b.allow:GetFontString():GetStringWidth() + 30)))
				b.allow.chatId = c.id
				b.allow.rules = denied
				b.allow:Show()
				extra = 28
			else
				b.allow:Hide()
			end
			b:SetHeight(6 + 12 + 4 + h + 8 + extra)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, -y)
			b.text = text
			b:Show()
			y = y + b:GetHeight() + 6
		end
		local last = #c.history
		for i, m in ipairs(c.history) do
			-- The Allow button only makes sense on the newest reply, and only while idle.
			local denied = (i == last and not c.pendingId and type(m.denied) == "table" and #m.denied > 0) and m.denied or nil
			Place(m.role, m.text, m.t and date("%H:%M", m.t) or "", false, denied)
		end
		if c.pendingId then
			local p = c.progress
			local head = "working... " .. ActivityLine(c)
			if run.statusText and run.statusText ~= "" then head = head .. "\n" .. run.statusText end
			Place("claude", (p and p ~= "") and (head .. "\n\n" .. p) or head, "", true)
		elseif #c.history == 0 then
			if run.restoring then
				Place("system", "Connecting to the bridge and restoring your chats...", "", true)
			elseif not WoWClaude.IsConnected() then
				Place("system", "Not connected to the bridge. Start it (npm start in the wow-claude folder, or wow-claude in your project), then click Connect below.", "", true)
			else
				Place("system", "Click the box below and type to start. /wow-claude help lists the commands; /ai <text> and /r work from the game chat too.", "", true)
			end
		end
		for i = n + 1, #ui.bubbles do
			ui.bubbles[i]:Hide()
		end
		ui.content:SetHeight(math.max(y, 1))
		C_Timer.After(0.05, function()
			if ui.scroll then
				ui.scroll:SetVerticalScroll(ui.scroll:GetVerticalScrollRange())
			end
		end)
	end
	WoWClaude.UpdateStatus()
	WoWClaude.RenderChatList()
end

-- Copy box (/wow-claude copy): a selectable EditBox with the last reply pre-highlighted for Ctrl+C.
function WoWClaude.ShowCopy(text)
	if not ui.copy then
		local cf = CreateFrame("Frame", "WoWClaudeCopy", UIParent, "BackdropTemplate")
		cf:SetSize(560, 320)
		cf:SetPoint("CENTER")
		cf:SetFrameStrata("FULLSCREEN_DIALOG")
		cf:SetMovable(true)
		cf:SetClampedToScreen(true)
		cf:EnableMouse(true)
		cf:RegisterForDrag("LeftButton")
		cf:SetScript("OnDragStart", cf.StartMoving)
		cf:SetScript("OnDragStop", cf.StopMovingOrSizing)
		cf:SetBackdrop(BACKDROP)
		cf:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
		cf:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
		tinsert(UISpecialFrames, "WoWClaudeCopy")

		local t = cf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -12)
		t:SetText("Text is selected - press Ctrl+C, then Esc")

		local x = CreateFrame("Button", nil, cf, "UIPanelCloseButton")
		x:SetPoint("TOPRIGHT", cf, "TOPRIGHT", -4, -4)

		local sc = CreateFrame("ScrollFrame", "WoWClaudeCopyScroll", cf, "UIPanelScrollFrameTemplate")
		sc:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -36)
		sc:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -32, 14)
		local eb = CreateFrame("EditBox", "WoWClaudeCopyBox", sc)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject(ChatFontNormal)
		eb:SetMaxLetters(0)
		eb:SetSize(500, 260)
		eb:SetScript("OnEscapePressed", function() cf:Hide() end)
		sc:SetScrollChild(eb)
		sc:HookScript("OnSizeChanged", function(self, w) eb:SetWidth(w) end)
		ui.copy, ui.copyBox = cf, eb
	end
	ui.copyBox:SetText(text)
	ui.copy:Show()
	ui.copyBox:SetFocus()
	ui.copyBox:HighlightText()
end

function WoWClaude.RenderChatList()
	if not ui.chatButtons then return end
	for i, btn in ipairs(ui.chatButtons) do
		local c = db.chats[i]
		if c then
			local label = Display(c.name)
			local folder = FolderName(ChatFolder(c))
			if folder ~= "" and folder:lower() ~= c.name:lower() then
				label = label .. " |cff888888" .. Display(folder) .. "|r"
			end
			if c.pendingId then
				label = label .. " |cffffd100...|r"
			elseif (c.unread or 0) > 0 then
				label = label .. " |cff55ff55(" .. c.unread .. ")|r"
			end
			btn.label:SetText(label)
			btn.chatId = c.id
			btn.selected:SetShown(c.id == db.activeChat)
			btn:Show()
		else
			btn:Hide()
		end
	end
end

function WoWClaude.UpdateMini()
	if not ui.miniBadge then return end
	local unread, working = 0, 0
	for _, c in ipairs(db.chats) do
		unread = unread + (c.unread or 0)
		if c.pendingId then working = working + 1 end
	end
	local t
	if working > 0 and unread > 0 then
		t = "|cff55ff55" .. unread .. " new|r |cffffd100" .. working .. " working|r"
	elseif working > 0 then
		t = "|cffffd100" .. (working == 1 and "working..." or (working .. " working...")) .. "|r"
	elseif unread > 0 then
		t = "|cff55ff55" .. unread .. (unread == 1 and " new reply" or " new replies") .. "|r"
	else
		t = "|cff999999idle|r"
	end
	ui.miniBadge:SetText(t)
	if ui.miniPulse then
		if unread > 0 then
			if not ui.miniPulse:IsPlaying() then ui.miniPulse:Play() end
		else
			ui.miniPulse:Stop()
			ui.miniBadge:SetAlpha(1)
		end
	end
end

local ECHO_DEFAULT = 4000 -- characters of a reply to print into the game chat ("/wow-claude echo <n>")

local function ChatLinks(chat)
	return "  |Hclaude:reply:" .. chat.id .. "|h|cff55ff55[reply]|r|h |Hclaude:open:" .. chat.id .. "|h|cff7ec8ff[open]|r|h"
end

-- Print a reply into the game chat: prefix on the first line, then the text line
-- by line up to the limit, then clickable links. `short` prints one preview line.
local function EchoToChat(chat, text)
	local mode = db.settings.echo
	if mode == "off" then return end
	local prefix = "|cff7ec8ff[Claude · " .. Display(chat.name) .. "]|r "
	local body = Display(text)
	if mode == "short" then
		local flat = (body:gsub("%s+", " "))
		if #flat > 200 then flat = flat:sub(1, 200) .. " ..." end
		print(prefix .. flat .. ChatLinks(chat))
		return
	end
	local limit = tonumber(mode) or ECHO_DEFAULT
	local first, shown = true, 0
	for line in (body .. "\n"):gmatch("(.-)\n") do
		if line:match("%S") then
			if shown + #line > limit then
				print("    |cff888888... " .. (#body - shown) .. " more characters, click [open] to read it all|r")
				break
			end
			print((first and prefix or "    ") .. line)
			first = false
			shown = shown + #line
		end
	end
	print("    " .. ChatLinks(chat):sub(3))
end

-- A reply landed. Always play the sound and echo it to the game chat; if that
-- chat isn't on screen, also flash the screen text and light up the mini bar.
function WoWClaude.Notify(chat, text)
	pcall(PlaySound, 3081)
	WoWClaude.UpdateMini()
	-- Until a real whisper arrives, /r replies to this chat.
	run.lastMessenger = "claude"
	run.lastReplyChat = chat.id
	EchoToChat(chat, text)
	if ui.frame and ui.frame:IsShown() and db.activeChat == chat.id then return end
	if UIErrorsFrame then
		UIErrorsFrame:AddMessage("Claude replied in " .. Display(chat.name), 0.5, 0.8, 1, 1)
	end
end

-- /r goes to Claude when Claude was the last one to message you, exactly like
-- whisper reply, and the box shows a "To Claude [chat]:" header while you type.
--
-- The chat type underneath is left alone (a custom type would leak into chat
-- settings); instead the box remembers a Claude target, the header is repainted
-- over the game's own, and the send entry points are intercepted. Any other chat
-- type, Tab, Esc or a cleared box drops the target again.
local CLAUDE_R, CLAUDE_G, CLAUDE_B = 0.49, 0.78, 1.0

local function PaintClaudeHeader(eb, chat)
	local header = _G[eb:GetName() .. "Header"]
	local suffix = _G[eb:GetName() .. "HeaderSuffix"]
	if not header then return end
	eb.claudePainting = true
	eb:UpdateHeader() -- lay out normally first, then repaint
	eb.claudePainting = nil
	header:SetWidth(0)
	header:SetText("To Claude [" .. Display(chat.name) .. "]: ")
	header:SetTextColor(CLAUDE_R, CLAUDE_G, CLAUDE_B)
	if suffix then suffix:Hide() end
	eb:SetTextInsets(15 + header:GetWidth(), 13, 0, 0)
	eb:SetTextColor(CLAUDE_R, CLAUDE_G, CLAUDE_B)
end

local function SendBoxToClaude(eb)
	local chat = FindChat(eb.claudeTarget)
	local text = Trim(eb:GetText() or "")
	eb.claudeTarget = nil
	eb:ClearChat()
	if chat and db.activeChat ~= chat.id then WoWClaude.SwitchChat(chat.id) end
	if text ~= "" then
		WoWClaude.Send(text)
	else
		WoWClaude.Toggle(true)
		if ui.input then ui.input:SetFocus() end
	end
end

local function HookReplyCommand()
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local eb = _G["ChatFrame" .. i .. "EditBox"]
		if eb and eb.ProcessChatType and not eb.claudeReplyHooked then
			eb.claudeReplyHooked = true

			local origProcess = eb.ProcessChatType
			eb.ProcessChatType = function(self, msg, index, send, ...)
				if index ~= "REPLY" then
					self.claudeTarget = nil
					return origProcess(self, msg, index, send, ...)
				end
				if not (db and run.lastMessenger == "claude") then
					return origProcess(self, msg, index, send, ...)
				end
				local chat = FindChat(run.lastReplyChat) or ActiveChat()
				if send == 1 then
					self:SetText(msg or "")
					self.claudeTarget = chat and chat.id
					SendBoxToClaude(self)
					return true
				end
				self.claudeTarget = chat and chat.id
				self:SetText(msg or "")
				if chat then PaintClaudeHeader(self, chat) end
				return true
			end

			-- Enter arrives here; nothing below us ever sees a Claude-targeted box.
			for _, name in ipairs({ "SendMessage", "SendText" }) do
				local orig = eb[name]
				if orig then
					eb[name] = function(self, ...)
						if self.claudeTarget then
							SendBoxToClaude(self)
							return
						end
						return orig(self, ...)
					end
				end
			end

			-- Anything that repaints the header normally (Tab, /s, sticky reset) ends Claude mode.
			hooksecurefunc(eb, "UpdateHeader", function(self)
				if not self.claudePainting then self.claudeTarget = nil end
			end)
			hooksecurefunc(eb, "ClearChat", function(self)
				self.claudeTarget = nil
			end)
		end
	end
end

-- Clicks on our [reply] / [open] links in the chat frame.
hooksecurefunc("SetItemRef", function(link)
	local action, chatId = tostring(link):match("^claude:(%a+):(%w+)")
	if not action or not db then return end
	if FindChat(chatId) then WoWClaude.SwitchChat(chatId) end
	WoWClaude.Toggle(true)
	if action == "reply" and ui.input then ui.input:SetFocus() end
end)

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function MakeButton(parent, label, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b
end

local PANEL_W = 150

local function BuildUI()
	if ui.frame then return end
	local s = db.settings

	local f = CreateFrame("Frame", "WoWClaudeFrame", UIParent, "BackdropTemplate")
	ui.frame = f
	f:SetSize(s.width, s.height)
	if s.point then
		f:SetPoint(s.point, UIParent, s.relPoint or s.point, s.x or 0, s.y or 0)
	else
		f:SetPoint("CENTER")
	end
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetResizable(true)
	f:SetClampedToScreen(true)
	f:SetResizeBounds(560, 300)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
	end)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
	f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	f:Hide()
	tinsert(UISpecialFrames, "WoWClaudeFrame")

	-- Status light: green = bridge seen recently, yellow = stale, red = gone.
	local function MakeDot(parent)
		local holder = CreateFrame("Frame", nil, parent)
		holder:SetSize(16, 16)
		local dot = holder:CreateTexture(nil, "OVERLAY")
		dot:SetAllPoints()
		dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
		holder:EnableMouse(true)
		holder:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(dot.tip or "Bridge status", 0.9, 0.9, 0.9, 1, true)
			GameTooltip:Show()
		end)
		holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return holder, dot
	end

	local dotHolder, dot = MakeDot(f)
	dotHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -16)
	ui.dot = dot

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("LEFT", dotHolder, "RIGHT", 6, 0)
	title:SetText("WoW Claude")
	ui.title = title

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -34)
	status:SetPoint("RIGHT", f, "RIGHT", -60, 0)
	status:SetJustifyH("LEFT")
	ui.status = status

	-- Minimize button in the corner where a close X would be: this window is never
	-- closed from here, only collapsed to the mini bar (Esc does the same, see OnHide).
	-- The mini bar's own X is the one that hides everything.
	local mini
	if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("RedButton-MiniCondense") then
		-- Blizzard's own minimize button: the close button's chrome with a "condense" glyph.
		local ok, b = pcall(CreateFrame, "Button", nil, f, "UIPanelHideButtonNoScripts")
		if ok and b then mini = b end
	end
	if not mini then
		-- Older art: draw a dash on a plain button.
		mini = CreateFrame("Button", nil, f)
		mini:SetSize(24, 24)
		local dash = mini:CreateTexture(nil, "ARTWORK")
		dash:SetSize(10, 2)
		dash:SetPoint("CENTER", mini, "CENTER", 0, -3)
		dash:SetColorTexture(0.9, 0.9, 0.9, 1)
		local hl = mini:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.15)
	end
	mini:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
	mini:SetScript("OnClick", function() WoWClaude.Minimize(true) end)
	mini:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Minimize to the small bar  (Esc)")
		GameTooltip:AddLine("Claude keeps working; the bar shows when a reply lands.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Esc (via UISpecialFrames) just calls Hide(); treat that as a minimize unless
	-- we're hiding on purpose. Ignore hides caused by the whole UI going away.
	f:SetScript("OnHide", function()
		if ui.quitting then
			ui.quitting = nil
			return
		end
		if not db or not db.settings.shown or not UIParent:IsShown() then return end
		db.settings.minimized = true
		if ui.mini then ui.mini:Show() end
		WoWClaude.UpdateMini()
	end)

	-- Left panel: chat list
	local panel = CreateFrame("Frame", nil, f, "BackdropTemplate")
	panel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -52)
	panel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 50)
	panel:SetWidth(PANEL_W)
	panel:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0, 0, 0, 0.4)
	panel:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	local newBtn = MakeButton(panel, "+ New chat", PANEL_W - 16, function() WoWClaude.NewChat() end)
	newBtn:SetPoint("TOP", panel, "TOP", 0, -8)

	-- Per-chat menu: Rename and Folder, opened by right-clicking a chat row. A
	-- plain frame of our own rather than a Blizzard dropdown, so it looks the
	-- same on every client.
	local menu = CreateFrame("Frame", "WoWClaudeChatMenu", f, "BackdropTemplate")
	menu:SetSize(110, 3 * 20 + 12)
	menu:SetFrameStrata("TOOLTIP")
	menu:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	menu:SetBackdropColor(0.08, 0.08, 0.1, 0.97)
	menu:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	menu:EnableMouse(true)
	menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	menu.title:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -8)
	menu.title:SetPoint("RIGHT", menu, "RIGHT", -8, 0)
	menu.title:SetJustifyH("LEFT")
	menu.title:SetWordWrap(false)
	local function MenuItem(label, order, onClick)
		local it = CreateFrame("Button", nil, menu)
		it:SetSize(110 - 12, 20)
		it:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -6 - order * 20)
		local hl = it:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.12)
		it.label = it:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		it.label:SetPoint("LEFT", it, "LEFT", 6, 0)
		it.label:SetText(label)
		it:SetScript("OnClick", function()
			menu:Hide()
			onClick(menu.chatId)
		end)
		return it
	end
	MenuItem("Rename...", 1, WoWClaude.RenamePrompt)
	MenuItem("Folder...", 2, WoWClaude.FolderPrompt)
	-- Close once the mouse has wandered away from the menu and the row it came from.
	menu:SetScript("OnUpdate", function(self, dt)
		if not MouseIsOver then return end
		if MouseIsOver(self) or (self.owner and MouseIsOver(self.owner)) then
			self.away = 0
		else
			self.away = (self.away or 0) + dt
			if self.away > 0.5 then self:Hide() end
		end
	end)
	menu:Hide()
	ui.chatMenu = menu

	function WoWClaude.ShowChatMenu(chatId, anchor)
		local c = FindChat(chatId)
		if not c then return end
		if menu:IsShown() and menu.chatId == chatId then
			menu:Hide()
			return
		end
		menu.chatId = chatId
		menu.owner = anchor
		menu.away = 0
		menu.title:SetText(Display(c.name))
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 8, 2)
		menu:Show()
	end

	ui.chatButtons = {}
	for i = 1, MAX_CHATS do
		local b = CreateFrame("Button", nil, panel)
		b:SetSize(PANEL_W - 16, 20)
		b:SetPoint("TOP", newBtn, "BOTTOM", 0, -6 - (i - 1) * 21)
		b.selected = b:CreateTexture(nil, "BACKGROUND")
		b.selected:SetAllPoints()
		b.selected:SetColorTexture(1, 1, 1, 0.12)
		b.selected:Hide()
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)

		-- Trash can: delete this chat (asks first). Blizzard's red delete button
		-- where the client has it, a plain X elsewhere.
		b.del = CreateFrame("Button", nil, b)
		b.del:SetSize(16, 16)
		b.del:SetPoint("RIGHT", b, "RIGHT", -2, 0)
		if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("128-RedButton-Delete") then
			b.del:SetNormalAtlas("128-RedButton-Delete")
			b.del:SetPushedAtlas("128-RedButton-Delete-Pressed")
			b.del:SetHighlightAtlas("128-RedButton-Delete-Highlight")
		else
			b.del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
			b.del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
		end
		b.del:SetAlpha(0.6)
		b.del:SetScript("OnClick", function() WoWClaude.ConfirmDelete(b.chatId) end)
		b.del:SetScript("OnEnter", function(self)
			self:SetAlpha(1)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Delete this chat")
			GameTooltip:Show()
		end)
		b.del:SetScript("OnLeave", function(self)
			self:SetAlpha(0.6)
			GameTooltip:Hide()
		end)

		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.label:SetPoint("LEFT", b, "LEFT", 6, 0)
		b.label:SetPoint("RIGHT", b.del, "LEFT", -4, 0)
		b.label:SetJustifyH("LEFT")
		b.label:SetWordWrap(false)
		-- Left-click switches to the chat; right-click opens its menu (Rename,
		-- Folder). A second right-click on the same row closes the menu again.
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				WoWClaude.ShowChatMenu(self.chatId, self)
			else
				WoWClaude.SwitchChat(self.chatId)
			end
		end)
		b:SetScript("OnDoubleClick", function(self)
			WoWClaude.SwitchChat(self.chatId)
			WoWClaude.RenamePrompt(self.chatId)
		end)
		b:Hide()
		ui.chatButtons[i] = b
	end

	-- Transcript: a scrolling stack of message bubbles
	local scroll = CreateFrame("ScrollFrame", "WoWClaudeScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 0)
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 110)
	ui.scroll = scroll

	local content = CreateFrame("Frame", "WoWClaudeContent", scroll)
	content:SetSize(500, 1)
	scroll:SetScrollChild(content)
	ui.content = content
	ui.bubbles = {}
	scroll:HookScript("OnSizeChanged", function(self, w, h)
		if ui.frame:IsShown() then WoWClaude.Render() end
	end)

	-- Input box, with Send docked at its right end like a messaging app.
	local SEND_W = 84
	local inputBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
	inputBg:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", 8, 0)
	inputBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14 - SEND_W - 6, 50)
	inputBg:SetHeight(54)
	inputBg:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	inputBg:SetBackdropColor(0, 0, 0, 0.6)
	inputBg:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

	local inScroll = CreateFrame("ScrollFrame", "WoWClaudeInputScroll", inputBg, "UIPanelScrollFrameTemplate")
	inScroll:SetPoint("TOPLEFT", inputBg, "TOPLEFT", 8, -6)
	inScroll:SetPoint("BOTTOMRIGHT", inputBg, "BOTTOMRIGHT", -24, 6)

	local input = CreateFrame("EditBox", "WoWClaudeInput", inScroll)
	input:SetMultiLine(true)
	input:SetAutoFocus(false)
	input:SetFontObject(ChatFontNormal)
	input:SetMaxLetters(0)
	input:SetSize(500, 40)
	input:SetScript("OnEnterPressed", function() WoWClaude.SendFromInput() end)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	inScroll:SetScrollChild(input)
	inScroll:HookScript("OnSizeChanged", function(self, w, h)
		input:SetWidth(w)
	end)
	inputBg:SetScript("OnMouseDown", function() input:SetFocus() end)
	ui.input = input

	-- Send sits to the right of the input box, vertically centred on it.
	local send = MakeButton(f, "Send", SEND_W, WoWClaude.SendFromInput)
	send:SetHeight(30)
	send:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	ui.send = send

	-- Connect stands in for Send until the bridge has been seen (see UpdateConnect).
	local connect = MakeButton(f, "Connect", SEND_W, WoWClaude.Connect)
	connect:SetHeight(30)
	connect:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	connect:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Connect to the bridge")
		GameTooltip:AddLine("The bridge must be running on this PC (npm start in wow-claude, or wow-claude in your project). The light turns green once it answers.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	connect:SetScript("OnLeave", function() GameTooltip:Hide() end)
	connect:Hide()
	ui.connect = connect

	-- Reload is the fallback transport's button; it sits apart on the right and
	-- only shows when a reload would do something (see UpdateStatus).
	local refresh = MakeButton(f, "Reload", 70, function() SafeReload() end)
	refresh:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 16)
	refresh:Hide()
	ui.refresh = refresh

	-- Bottom row: Clear, plus Resend while a message is in flight. Rename, Folder
	-- and Delete live on each chat row in the left panel.
	local clear = MakeButton(f, "Clear", 60, function()
		local c = ActiveChat()
		if c then wipe(c.history) end
		WoWClaude.Render()
	end)
	clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 16)

	local resend = MakeButton(f, "Resend", 70, WoWClaude.Resend)
	resend:SetPoint("LEFT", clear, "RIGHT", 6, 0)
	resend:Hide()
	ui.resend = resend

	-- A named, always-present button so a keybinding can click it (see /wow-claude bind).
	local hotkey = CreateFrame("Button", "WoWClaudeRefreshButton", UIParent)
	hotkey:SetSize(1, 1)
	hotkey:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
	hotkey:SetScript("OnClick", function()
		local c = ActiveChat()
		if c and c.pendingId then
			WoWClaude.Send("")
		else
			WoWClaude.Toggle()
		end
	end)

	local cwd = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	cwd:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 4)
	cwd:SetPoint("RIGHT", f, "RIGHT", -30, 0)
	cwd:SetJustifyH("LEFT")
	cwd:SetWordWrap(false)
	ui.cwd = cwd

	-- Resize grip
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		s.width, s.height = f:GetSize()
	end)

	-- Mini bar: what the window collapses into. Click it to expand, drag to move.
	local m = CreateFrame("Frame", "WoWClaudeMini", UIParent, "BackdropTemplate")
	ui.mini = m
	m:SetSize(250, 30)
	if s.miniPoint then
		m:SetPoint(s.miniPoint, UIParent, s.miniRelPoint or s.miniPoint, s.miniX or 0, s.miniY or 0)
	else
		m:SetPoint("TOP", UIParent, "TOP", 0, -40)
	end
	m:SetFrameStrata("DIALOG")
	m:SetMovable(true)
	m:SetClampedToScreen(true)
	m:EnableMouse(true)
	m:RegisterForDrag("LeftButton")
	m:SetScript("OnDragStart", function(self)
		self.dragging = true
		self:StartMoving()
	end)
	m:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.miniPoint, s.miniRelPoint, s.miniX, s.miniY = point, relPoint, x, y
		C_Timer.After(0, function() self.dragging = nil end)
	end)
	m:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and not self.dragging then
			WoWClaude.Minimize(false)
		end
	end)
	m:SetBackdrop(BACKDROP)
	m:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
	m:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	m:Hide()

	local miniDotHolder, miniDot = MakeDot(m)
	miniDotHolder:SetPoint("LEFT", m, "LEFT", 9, 0)
	ui.miniDot = miniDot

	local mlabel = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	mlabel:SetPoint("LEFT", miniDotHolder, "RIGHT", 6, 0)
	mlabel:SetText("WoW Claude")

	local badge = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	badge:SetPoint("LEFT", mlabel, "RIGHT", 8, 0)
	badge:SetPoint("RIGHT", m, "RIGHT", -26, 0)
	badge:SetJustifyH("LEFT")
	badge:SetWordWrap(false)
	ui.miniBadge = badge

	local ok, pulse = pcall(function()
		local g = badge:CreateAnimationGroup()
		local a1 = g:CreateAnimation("Alpha")
		a1:SetFromAlpha(1)
		a1:SetToAlpha(0.25)
		a1:SetDuration(0.6)
		a1:SetOrder(1)
		local a2 = g:CreateAnimation("Alpha")
		a2:SetFromAlpha(0.25)
		a2:SetToAlpha(1)
		a2:SetDuration(0.6)
		a2:SetOrder(2)
		g:SetLooping("REPEAT")
		return g
	end)
	if ok then ui.miniPulse = pulse end

	local mclose = CreateFrame("Button", nil, m, "UIPanelCloseButton")
	mclose:SetSize(24, 24)
	mclose:SetPoint("RIGHT", m, "RIGHT", -2, 0)
	mclose:SetScript("OnClick", function() WoWClaude.Toggle(false) end)
	mclose:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Quit: hide completely (/wow-claude brings it back)")
		GameTooltip:Show()
	end)
	mclose:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function WoWClaude.Toggle(show)
	if not ui.frame then return end
	if show == nil then show = not ui.frame:IsShown() end
	if show then
		db.settings.minimized = false
		local c = ActiveChat()
		if c then c.unread = 0 end
	end
	if ui.mini then ui.mini:Hide() end
	if not show then ui.quitting = true end
	ui.frame:SetShown(show)
	ui.quitting = nil
	db.settings.shown = show
	if show then
		WoWClaude.Render()
		-- No auto-focus: the game keeps the keyboard until you click the box.
		-- No automatic hello either: if the bridge hasn't been seen, the panel
		-- shows Connect in place of Send and waits for a click.
	end
	WoWClaude.UpdateMini()
end

function WoWClaude.Minimize(mini)
	if not ui.frame then return end
	if mini == nil then mini = not db.settings.minimized end
	if mini then
		db.settings.minimized = true
		db.settings.shown = true
		ui.frame:Hide() -- OnHide shows the mini bar
		if ui.mini and not ui.mini:IsShown() then ui.mini:Show() end
		WoWClaude.UpdateMini()
	else
		WoWClaude.Toggle(true)
	end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local HELP = table.concat({
	"/wow-claude                        toggle the window (/claude works too)",
	"/wow-claude mini                   collapse to the small bar (click the bar to expand)",
	"/wow-claude hide                   hide the window completely",
	"/ai <text>                         send <text> to the current chat straight from the game chat box",
	"/r <text>                          replies to Claude when Claude was the last to message you (else normal whisper reply)",
	"/wow-claude <text>                 same as /ai",
	"/wow-claude echo full|short|off|<chars>   how much of each reply to print in the game chat",
	"/wow-claude longchat on|off        let the game chat box take 4000 characters (for long /ai messages)",
	"/wow-claude new [name]             start a new chat (its own Claude session, like a new terminal)",
	"/wow-claude chat <n|name>          switch chats (or click one in the left panel)",
	"/wow-claude rename [name]          rename the current chat (no name = dialog; right-clicking the chat in the left panel offers it too)",
	"/wow-claude delete                 delete the current chat",
	"/wow-claude cd <folder>            folder this chat's Claude works in (relative to the bridge's folder; no folder = back to default). Right-clicking the chat in the left panel and picking Folder does the same",
	"/wow-claude reset                  next message in this chat starts a fresh Claude session",
	"/wow-claude mode pixel             no-reload transport (default)",
	"/wow-claude mode reload            fallback transport: a /reload per step",
	"/wow-claude resend                 show the strip again if the bridge missed it",
	"/wow-claude reload                 reload now (also frees the slot pool)",
	"/wow-claude cancel                 stop waiting on this chat's reply",
	"/wow-claude copy                   open the last reply in a selectable box for Ctrl+C",
	"/wow-claude bind <key>             hotkey: checks for a reply while waiting, else toggles the window",
	"/wow-claude auto on|off            reload-mode only: auto-reload on your next keypress after the interval",
	"/wow-claude signal on|off          the cheap sound-file readiness check (off if it spams errors)",
	"/wow-claude slots                  how many reply slots are still free this session",
	"/wow-claude diag                   transport diagnostics (is the cheap sound-file channel working?)",
	"/wow-claude clear                  clear this chat's transcript",
}, "\n")

-- /ai <text>: send straight from the game chat box (like /r, but for Claude).
SLASH_CLAUDEASK1 = "/ai"
SLASH_CLAUDEASK2 = "/ask"
SlashCmdList["CLAUDEASK"] = function(msg)
	msg = Trim(msg or "")
	if msg == "" then
		WoWClaude.Toggle(true)
	else
		WoWClaude.Send(msg)
	end
end

local function ApplyLongChat()
	local box = ChatFrame1EditBox
	if not box or not box.SetMaxLetters then return end
	box:SetMaxLetters(db.settings.longchat and 4000 or 255)
end

SLASH_WOWCLAUDE1 = "/wow-claude"
SLASH_WOWCLAUDE2 = "/claude"
SlashCmdList["WOWCLAUDE"] = function(msg)
	msg = Trim(msg or "")
	local cmd, rest = msg:match("^(%S+)%s*(.-)$")
	cmd = cmd and cmd:lower() or ""
	local s = db.settings
	local c = ActiveChat()

	if cmd == "" then
		WoWClaude.Toggle()
	elseif cmd == "mini" or cmd == "min" then
		WoWClaude.Minimize(true)
	elseif cmd == "new" then
		WoWClaude.NewChat(rest)
	elseif cmd == "chat" or cmd == "chats" then
		local n = tonumber(rest)
		local target = n and db.chats[n]
		if not target and rest ~= "" then
			for _, ch in ipairs(db.chats) do
				if ch.name:lower() == rest:lower() then target = ch end
			end
		end
		if target then
			WoWClaude.SwitchChat(target.id)
		else
			local lines = {}
			for i, ch in ipairs(db.chats) do
				table.insert(lines, i .. ". " .. ch.name .. (ch.id == db.activeChat and "  (current)" or "") .. (ch.pendingId and "  working" or "") .. ((ch.unread or 0) > 0 and ("  " .. ch.unread .. " new") or ""))
			end
			AddHistory(c, "system", "Chats:\n" .. table.concat(lines, "\n"))
			WoWClaude.Render()
		end
		WoWClaude.Toggle(true)
	elseif cmd == "rename" then
		if rest ~= "" then
			c.name = rest:sub(1, 24)
			WoWClaude.Render()
		else
			WoWClaude.RenameActive()
		end
		WoWClaude.Toggle(true)
	elseif cmd == "delete" then
		WoWClaude.DeleteChat()
	elseif cmd == "cd" then
		WoWClaude.SetFolder(rest, c)
		WoWClaude.Toggle(true)
	elseif cmd == "reset" then
		c.resetNext = true
		AddHistory(c, "system", "Next message starts a fresh Claude session in " .. c.cwd)
		WoWClaude.Render()
		WoWClaude.Toggle(true)
	elseif cmd == "mode" then
		if rest == "pixel" or rest == "reload" then
			s.mode = rest
			AddHistory(c, "system", "mode set to " .. rest)
		else
			AddHistory(c, "system", "mode is " .. s.mode .. " (pixel or reload)")
		end
		WoWClaude.Render()
		WoWClaude.Toggle(true)
	elseif cmd == "resend" then
		WoWClaude.Resend()
	elseif cmd == "auto" then
		local n = tonumber(rest)
		if n then
			s.interval = math.max(5, math.floor(n))
			s.autoRefresh = true
		elseif rest == "on" then
			s.autoRefresh = true
		elseif rest == "off" then
			s.autoRefresh = false
		end
		WoWClaude.UpdateStatus()
		WoWClaude.ArmAutoRefresh()
	elseif cmd == "hide" or cmd == "quit" then
		WoWClaude.Toggle(false)
	elseif cmd == "copy" then
		for i = #c.history, 1, -1 do
			if c.history[i].role == "claude" then
				WoWClaude.ShowCopy(c.history[i].text)
				break
			end
		end
	elseif cmd == "echo" then
		if rest == "full" or rest == "short" or rest == "off" then
			s.echo = rest
		elseif tonumber(rest) then
			s.echo = tostring(math.max(200, math.floor(tonumber(rest))))
		end
		AddHistory(c, "system", "replies in game chat: " .. s.echo .. " (full = " .. ECHO_DEFAULT .. " chars, short, off, or a number of characters)")
		WoWClaude.Render()
	elseif cmd == "longchat" then
		if rest == "on" then s.longchat = true elseif rest == "off" then s.longchat = false end
		ApplyLongChat()
		AddHistory(c, "system", "game chat box limit: " .. (s.longchat and "4000 characters (fine for /ai; real chat over 255 may be rejected by the server)" or "255 (default)"))
		WoWClaude.Render()
	elseif cmd == "signal" then
		if rest == "on" then s.signal = true elseif rest == "off" then s.signal = false end
		AddHistory(c, "system", "signal check is " .. (s.signal and "on" or "off"))
		WoWClaude.Render()
	elseif cmd == "slots" then
		local free = 0
		for i = 1, SLOT_COUNT do
			if not C_AddOns.IsAddOnLoaded(SlotName(i)) then free = free + 1 end
		end
		AddHistory(c, "system", free .. " of " .. SLOT_COUNT .. " reply slots free this session (a reload frees all)")
		WoWClaude.Render()
		WoWClaude.Toggle(true)
	elseif cmd == "refresh" or cmd == "reload" then
		SafeReload()
	elseif cmd == "bind" then
		local key = rest:upper()
		if key ~= "" and not InCombatLockdown() then
			SetBinding(key, "CLICK WoWClaudeRefreshButton:LeftButton")
			SaveBindings(GetCurrentBindingSet())
			AddHistory(c, "system", key .. " is now bound: checks for a reply while waiting, otherwise toggles this window")
		end
		WoWClaude.Render()
		WoWClaude.Toggle(true)
	elseif cmd == "diag" then
		local free = 0
		for i = 1, SLOT_COUNT do
			if not C_AddOns.IsAddOnLoaded(SlotName(i)) then free = free + 1 end
		end
		local lines = {
			"sound channel: " .. (signalAvailable and "usable" or "UNUSABLE") .. " (self-test: " .. tostring(signalStats.selftest) .. ")" .. (signalStats.error and (" error: " .. signalStats.error) or ""),
			"signal setting: " .. tostring(s.signal) .. ", marked unreliable this session: " .. tostring(run.signalUnreliable or false),
			"sound checks: " .. signalStats.checks .. ", valid hits: " .. signalStats.hits .. (signalStats.lastHit and (", last hit " .. FmtDur(GetTime() - signalStats.lastHit) .. " ago") or ""),
			"slot polls this session: " .. (run.polls or 0) .. ", free slots: " .. free .. "/" .. SLOT_COUNT,
			"presence: head at " .. tostring(run.presence and run.presence.last or "?") .. ", beats seen: " .. tostring(run.presence and run.presence.beats or 0),
			select(5, WoWClaude.BridgeState()),
			"mode: " .. s.mode .. ", session token: " .. tostring(db.session),
		}
		for _, ch in ipairs(db.chats) do
			local a = run.act and run.act[ch.id]
			if ch.pendingId then
				table.insert(lines, ch.name .. ": pending #" .. ch.pendingId .. (a and (", heartbeat " .. (a.unreliable and "unreliable" or (a.count .. " beats"))) or ", no heartbeat state"))
			end
		end
		AddHistory(c, "system", "Diagnostics:\n" .. table.concat(lines, "\n"))
		WoWClaude.Render()
		WoWClaude.Toggle(true)
	elseif cmd == "cancel" then
		if c.pendingId then
			AddHistory(c, "system", "Gave up waiting on #" .. c.pendingId)
			run.outbound[c.pendingId] = nil
			if run.act then run.act[c.id] = nil end
			c.pendingId = nil
			c.progress = nil
			RefreshStrip()
			if not AnyPending() then keyCatcher:Hide() end
		end
		WoWClaude.Render()
	elseif cmd == "clear" then
		wipe(c.history)
		WoWClaude.Render()
	elseif cmd == "help" then
		AddHistory(c, "system", HELP)
		WoWClaude.Render()
		WoWClaude.Toggle(true)
	else
		WoWClaude.Send(msg)
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("CHAT_MSG_BN_WHISPER")
ev:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			InitDB()
		end
	elseif event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER" then
		-- A real person whispered: /r belongs to them again.
		run.lastMessenger = "player"
	elseif event == "PLAYER_LOGIN" then
		if not db then InitDB() end
		BuildUI()
		run = { outbound = {} }
		SelfTestSignals()
		ProcessInbox()
		if AnyPending() then
			-- Still waiting after a reload: resume polling with a fresh slot pool.
			run.sentAt = GetTime()
			run.polls = 0
			run.act = {}
			for _, ch in ipairs(db.chats) do
				if ch.pendingId then
					-- Beats already written stay valid, so the counter catches up on its own.
					run.act[ch.id] = { next = 1, count = 0, startedAt = GetTime() }
				end
			end
			ScheduleNextPoll()
		end
		local c = ActiveChat()
		if c and c.draft and c.draft ~= "" then
			ui.input:SetText(c.draft)
			if not c.pendingId then c.draft = nil end
		end
		WoWClaude.Render()
		if db.settings.shown then
			if db.settings.minimized then
				WoWClaude.Minimize(true)
			else
				WoWClaude.Toggle(true)
			end
		end
		WoWClaude.ArmAutoRefresh()
		WoWClaude.UpdateDot()
		if db.settings.longchat then ApplyLongChat() end
		HookReplyCommand()
		C_Timer.NewTicker(TICK_SECONDS, Tick)
		C_Timer.After(3, WoWClaude.SayHello)
	elseif event == "PLAYER_REGEN_ENABLED" then
		if WoWClaude.reloadAfterCombat then
			WoWClaude.reloadAfterCombat = nil
			ReloadUI()
		elseif db then
			WoWClaude.ArmAutoRefresh()
		end
	end
end)
