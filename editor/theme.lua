-- PAGER's silver and black ReaImGui theme.
local theme = {}

-- Keep palette values in conventional 8-bit RGBA form. ReaImGui receives
-- the packed equivalent internally.
local function rgba(r, g, b, a)
  return (r << 24) | (g << 16) | (b << 8) | a
end

local COLORS = {
  { 'Col_WindowBg',         rgba(17, 17, 17, 255) },
  { 'Col_ChildBg',          rgba(17, 17, 17, 255) },
  { 'Col_PopupBg',          rgba(28, 28, 28, 255) },
  { 'Col_TitleBg',          rgba(30, 30, 30, 255) },
  { 'Col_TitleBgActive',    rgba(90, 90, 90, 255) },
  { 'Col_TitleBgCollapsed', rgba(22, 22, 22, 255) },
  { 'Col_FrameBg',          rgba(45, 45, 45, 255) },
  { 'Col_FrameBgHovered',   rgba(90, 90, 90, 255) },
  { 'Col_FrameBgActive',    rgba(141, 141, 141, 255) },
  { 'Col_Button',           rgba(45, 45, 45, 255) },
  { 'Col_ButtonHovered',    rgba(90, 90, 90, 255) },
  { 'Col_ButtonActive',     rgba(141, 141, 141, 255) },
  { 'Col_Header',           rgba(45, 45, 45, 255) },
  { 'Col_HeaderHovered',    rgba(90, 90, 90, 255) },
  { 'Col_HeaderActive',     rgba(141, 141, 141, 255) },
  { 'Col_Tab',              rgba(45, 45, 45, 255) },
  { 'Col_TabHovered',       rgba(90, 90, 90, 255) },
  { 'Col_TabSelected',      rgba(45, 45, 45, 255) },
  { 'Col_TabSelectedOverline', rgba(141, 141, 141, 255) },
  { 'Col_TabDimmed',        rgba(30, 30, 30, 255) },
  { 'Col_TabDimmedSelected', rgba(45, 45, 45, 255) },
  { 'Col_TabDimmedSelectedOverline', rgba(75, 75, 75, 255) },
  { 'Col_SliderGrab',       rgba(141, 141, 141, 255) },
  { 'Col_SliderGrabActive', rgba(190, 190, 190, 255) },
  { 'Col_CheckMark',        rgba(190, 190, 190, 255) },
  { 'Col_Text',             rgba(220, 220, 220, 255) },
  { 'Col_TextDisabled',     rgba(130, 130, 130, 255) },
  { 'Col_TextSelectedBg',   rgba(90, 90, 90, 255) },
  { 'Col_InputTextCursor',  rgba(220, 220, 220, 255) },
  { 'Col_NavCursor',        rgba(190, 190, 190, 255) },
  { 'Col_Border',           rgba(141, 141, 141, 255) },
  { 'Col_Separator',        rgba(75, 75, 75, 255) },
  { 'Col_SeparatorHovered', rgba(141, 141, 141, 255) },
  { 'Col_SeparatorActive',  rgba(190, 190, 190, 255) },
  { 'Col_ModalWindowDimBg', rgba(0, 0, 0, 160) },
}

local VARS = {
  { 'StyleVar_FrameRounding', 5.0 },
  { 'StyleVar_GrabRounding',  5.0 },
  { 'StyleVar_ChildRounding', 4.0 },
  { 'StyleVar_WindowRounding', 5.0 },
  { 'StyleVar_PopupRounding',  5.0 },
  { 'StyleVar_PopupBorderSize', 1.0 },
}

-- The one font every PAGER window draws with. Declared here rather than in
-- each tool so the launcher, the Effects Editor and MIDI Export cannot drift
-- apart: one family, one size, measured the same way everywhere.
--
-- 'sans-serif' is a ReaImGui generic family name, resolved to whatever the
-- host system uses. It needs no font file shipped with the package.
theme.FONT_FAMILY = 'sans-serif'
theme.FONT_SIZE = 14

-- Fonts are per-context resources: a font object must be attached to the
-- context that draws with it, and a context is destroyed when its tool closes.
-- So one font is created and cached per context rather than once per module
-- -- a font held over from a destroyed context is a dead handle.
--
-- Keyed weakly, so a closed tool's entry can be collected rather than pinning
-- a dead context for the rest of the session.
--
-- Weak keys alone are NOT enough to make a hit trustworthy. REAPER reuses the
-- address of a released context for the next one, and the old entry survives
-- until a GC cycle that may not have run yet -- so a lookup can hit on a new
-- context and hand back the font attached to the destroyed one. PushFont then
-- fails with "expected a valid ImGui_Font*", which is what closing a tool and
-- reopening PAGER used to do.
--
-- So the handle is revalidated on every lookup instead of trusted. This is
-- the pattern ReaImGui's own docs use for cached resources (see the image
-- cache in api/image.cpp).
local fonts = setmetatable({}, { __mode = 'k' })

-- Create and attach this context's font, or return the one already made.
-- Attach must happen before the first frame that uses the font.
function theme.font(ctx, ImGui)
  local f = fonts[ctx]
  -- A stale entry is indistinguishable from a live one by identity alone;
  -- only ValidatePtr can tell, because the address may have been recycled.
  if f and not ImGui.ValidatePtr(f, 'ImGui_Font*') then f = nil end
  if not f then
    f = ImGui.CreateFont(theme.FONT_FAMILY)
    ImGui.Attach(ctx, f)
    fonts[ctx] = f
  end
  return f
end

function theme.push(ctx, ImGui)
  for _, color in ipairs(COLORS) do
    ImGui.PushStyleColor(ctx, ImGui[color[1]], color[2])
  end
  for _, var in ipairs(VARS) do
    ImGui.PushStyleVar(ctx, ImGui[var[1]], var[2])
  end
end

function theme.pop(ctx, ImGui)
  ImGui.PopStyleVar(ctx, #VARS)
  ImGui.PopStyleColor(ctx, #COLORS)
end

-- Font and style together, for a tool that wants the whole presentation in
-- one call. Balanced against theme.end_frame: one PushFont and one PushStyle*
-- run here, one PopFont and the matching pops run there. A tool that needs to
-- push the font itself (to measure text before Begin at a known size) can
-- still use theme.font/push directly -- these two are the common path.
function theme.begin_frame(ctx, ImGui, size)
  ImGui.PushFont(ctx, theme.font(ctx, ImGui), size or theme.FONT_SIZE)
  theme.push(ctx, ImGui)
end

function theme.end_frame(ctx, ImGui)
  theme.pop(ctx, ImGui)
  ImGui.PopFont(ctx)
end

return theme
