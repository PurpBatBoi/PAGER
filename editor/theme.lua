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

return theme
