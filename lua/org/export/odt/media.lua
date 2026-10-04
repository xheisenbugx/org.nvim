---@mod org.export.odt.media ODT images and formulas
---
--- Embedding pictures and formulas: copying them into the package,
--- sizes, frames and the inline image / formula markup.
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local zip = require("org.export.zip")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format

local read_file = shared.read_file
local DEFAULT_IMAGE_SIZES = shared.DEFAULT_IMAGE_SIZES
local MAX_IMAGE_SIZE = shared.MAX_IMAGE_SIZE
local state = shared.state
local manifest_entry = shared.manifest_entry
local num = shared.num
local frame = shared.frame
local textbox = shared.textbox
local standalone_link_p = shared.standalone_link_p
local labelled = shared.labelled
local PREDICATES = shared.PREDICATES
local format_label = shared.format_label

---------------------------------------------------------------------------
-- Images and formulas
---------------------------------------------------------------------------

local MEDIA = { jpg = "jpeg", svg = "svg+xml", tif = "tiff" }

--- org-odt--copy-image-file: embed `path` as Images/NNNN.ext.
local function copy_image_file(info, path)
  local data = read_file(path, true)
  if not data then
    error("Cannot read image file " .. path, 0)
  end
  local st = state(info)
  local ext = (path:match("%.([%w]+)$") or "png"):lower()
  st.images = st.images + 1
  local name = fmt("Images/%04d.%s", st.images, ext)
  if st.images == 1 then
    manifest_entry(info, "", "Images/")
    table.insert(st.files, { name = "Images/" })
  end
  table.insert(st.files, { name = name, data = data })
  manifest_entry(info, "image/" .. (MEDIA[ext] or ext), name)
  return name
end

--- Pixel size of an image: PNG, GIF and JPEG headers, then ImageMagick's
--- identify, then the width/height of an SVG.
function M.image_pixel_size(path)
  local s = read_file(path, true)
  if not s then
    return nil
  end
  local function be16(i)
    local a, b = s:byte(i, i + 1)
    return a * 256 + b
  end
  if s:sub(1, 8) == "\137PNG\r\n\26\n" and #s >= 24 then
    return be16(17) * 65536 + be16(19), be16(21) * 65536 + be16(23)
  elseif s:sub(1, 4) == "GIF8" and #s >= 10 then
    local a, b, c, d = s:byte(7, 10)
    return a + b * 256, c + d * 256
  elseif s:sub(1, 2) == "\255\216" then
    local i = 3
    while i + 9 <= #s do
      if s:byte(i) ~= 255 then
        break
      end
      local marker = s:byte(i + 1)
      local len = be16(i + 2)
      if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
        return be16(i + 7), be16(i + 5)
      end
      i = i + 2 + len
    end
  end
  if vim.fn.executable("identify") == 1 then
    local res = vim.system({ "identify", "-format", "%w:%h", path }, { text = true }):wait()
    local w, h = (res.stdout or ""):match("(%d+):(%d+)")
    if w then
      return tonumber(w), tonumber(h)
    end
  end
  local svg = s:match("<svg[^>]*>")
  if svg then
    local w = tonumber(svg:match('%swidth="([%d%.]+)[p]?[x]?"'))
    local h = tonumber(svg:match('%sheight="([%d%.]+)[p]?[x]?"'))
    if not (w and h) then
      local vb = svg:match('viewBox="([^"]+)"')
      if vb then
        local nums = {}
        for n in vb:gmatch("[%-%d%.]+") do
          nums[#nums + 1] = tonumber(n)
        end
        w, h = nums[3], nums[4]
      end
    end
    if w and h then
      return w, h
    end
  end
  return nil
end

--- org-odt--image-size: { width, height } in cm.
local function image_size(file, info, user_width, user_height, scale, dpi, embed_as)
  dpi = dpi or info.odt_pixels_per_inch or 96
  if scale then
    user_width, user_height = nil, nil
  end
  local width, height
  if not (user_width and user_height) then
    local pw, ph = M.image_pixel_size(file)
    if pw and ph and pw > 0 and ph > 0 then
      width, height = pw / dpi * 2.54, ph / dpi * 2.54
    else
      local d = DEFAULT_IMAGE_SIZES[embed_as or "paragraph"] or DEFAULT_IMAGE_SIZES.paragraph
      width, height = d[1], d[2]
    end
  end
  if scale then
    width, height = width * scale, height * scale
  elseif user_width and user_height then
    width, height = user_width, user_height
  elseif user_height then
    width, height = user_height * (width / height), user_height
  elseif user_width then
    width, height = user_width, user_width * (height / width)
  end
  local mw, mh = MAX_IMAGE_SIZE[1], MAX_IMAGE_SIZE[2]
  if width > mw or height > mh then
    local s = math.min(mw / width, mh / height)
    width, height = width * s, height * s
  end
  return width, height
end

local FRAME_CFG = {
  ["As-CharImage"] = { { "OrgInlineImage", nil, "as-char" } },
  ParagraphImage = { { "OrgDisplayImage", nil, "paragraph" } },
  PageImage = { { "OrgPageImage", nil, "page" } },
  ["CaptionedAs-CharImage"] = {
    { "OrgCaptionedImage", ' style:rel-width="100%" style:rel-height="scale"', "paragraph" },
    { "OrgInlineImage", nil, "as-char" },
  },
  CaptionedParagraphImage = {
    { "OrgCaptionedImage", ' style:rel-width="100%" style:rel-height="scale"', "paragraph" },
    { "OrgImageCaptionFrame", nil, "paragraph" },
  },
  CaptionedPageImage = {
    { "OrgCaptionedImage", ' style:rel-width="100%" style:rel-height="scale"', "paragraph" },
    { "OrgPageImageCaptionFrame", nil, "page" },
  },
  InlineFormula = { { "OrgInlineFormula", nil, "as-char" } },
  DisplayFormula = { { "OrgDisplayFormula", nil, "as-char" } },
  CaptionedDisplayFormula = {
    { "OrgCaptionedFormula", nil, "paragraph" },
    { "OrgFormulaCaptionFrame", nil, "paragraph" },
  },
}

--- org-odt--render-image/formula
local function render_image_formula(info, key, href, width, height, captions, user, title, desc)
  local cfg = FRAME_CFG[key] or FRAME_CFG.ParagraphImage
  local inner, outer = cfg[1], cfg[2]
  local caption = captions and captions[1]
  local function merge(default, u)
    if not u then
      return default
    end
    return { u[1] or default[1], u[2] or default[2], u[3] or default[3] }
  end
  if not caption or not outer then
    inner = merge(inner, user)
    return frame(info, href, width, height, inner[1], inner[2], inner[3], title, desc)
  end
  outer = merge(outer, user)
  return textbox(
    info,
    fmt(
      '\n<text:p text:style-name="%s">%s</text:p>',
      "Illustration",
      frame(info, href, width, height, inner[1], inner[2], inner[3], title, desc) .. caption
    ),
    width,
    height,
    outer[1],
    outer[2],
    outer[3]
  )
end

local function input_dir(info)
  return info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
end

local function expand_path(path, info)
  -- link paths are document text: never vim.fn.expand() (`backticks`)
  path = require("org.utils").expand_vars(path)
  if path:match("^/") or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(input_dir(info) .. "/" .. path)
end

--- org-odt-link--inline-image: `node` is an image link or a LaTeX fragment
--- rendered as an image (`file` is then the rendered picture).
local function inline_image(node, info, file, title, desc)
  local src = file or expand_path(node.path, info)
  local href = fmt(
    '\n<draw:image xlink:href="%s" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/>',
    copy_image_file(info, src)
  )
  local attr_from = element.parent_element(node)
  local attrs = attr_from and ox.read_attribute("attr_odt", attr_from) or { _keys = {} }
  local anchor = attrs.anchor and attrs.anchor:lower()
  if anchor ~= "as-char" and anchor ~= "paragraph" and anchor ~= "page" then
    anchor = nil
  end
  local user = { anchor and attrs.style or nil, anchor and attrs.attributes or nil, anchor }
  local width, height =
    image_size(src, info, num(attrs.width), num(attrs.height or attrs.length), num(attrs.scale), nil, "paragraph")
  local standalone = standalone_link_p(node, info)
  local embed_as = standalone and "paragraph" or "as-char"
  local captions
  if standalone and node.parent and PREDICATES.__Figure__(node.parent, info) then
    captions = format_label(node.parent, info, "definition", "__Figure__")
  end
  -- the anchor of #+ATTR_ODT only overrides the frame parameters
  local entity = (captions and "Captioned" or "") .. (embed_as == "paragraph" and "Paragraph" or "As-Char") .. "Image"
  return render_image_formula(info, entity, href, width, height, captions, user, title, desc)
end

--- Embed a formula (MathML text or an .odf/.mml file) as Formula-NNNN/.
local function copy_formula(info, data)
  local st = state(info)
  st.formulas = st.formulas + 1
  local dir = fmt("Formula-%04d/", st.formulas)
  manifest_entry(info, "application/vnd.oasis.opendocument.formula", dir, "1.2")
  table.insert(st.files, { name = dir })
  table.insert(st.files, { name = dir .. "content.xml", data = data })
  manifest_entry(info, "text/xml", dir .. "content.xml")
  return dir
end

local function formula_file_data(path)
  local ext = (path:match("%.([%w]+)$") or ""):lower()
  if ext == "mathml" or ext == "mml" then
    local data = read_file(path, true)
    if not data then
      error("Cannot read formula file " .. path, 0)
    end
    return data
  elseif ext == "odf" then
    local data, err = zip.read(path, "content.xml")
    if not data then
      error(err, 0)
    end
    return data
  end
  error(path .. " is not a formula file", 0)
end

--- org-odt-link--inline-formula: `unit` is the paragraph (or LaTeX
--- environment) holding the formula when it is displayed.
local function inline_formula(info, data, standalone, unit, title, desc)
  local dir = copy_formula(info, data)
  local href =
    fmt('\n<draw:object %s xlink:href="%s" xlink:type="simple"/>', ' xlink:show="embed" xlink:actuate="onLoad"', dir)
  if not standalone then
    return render_image_formula(info, "InlineFormula", href, nil, nil, nil, nil, title, desc)
  end
  local captions = unit and labelled(unit) and format_label(unit, info, "definition", "__MathFormula__") or nil
  local equation = render_image_formula(info, "CaptionedDisplayFormula", href, nil, nil, captions, nil, title, desc)
  local label = unit and labelled(unit) and format_label(unit, info, "definition", "__MathFormula__", "math-label")
    or nil
  return equation .. "<text:tab/>" .. (label and label[1] or "")
end

-- Locals the later parts share
shared.MEDIA = MEDIA
shared.copy_image_file = copy_image_file
shared.image_size = image_size
shared.render_image_formula = render_image_formula
shared.expand_path = expand_path
shared.inline_image = inline_image
shared.formula_file_data = formula_file_data
shared.inline_formula = inline_formula
