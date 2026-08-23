--[[
Rendered HTML for the post and comment views (DESIGN.md §5.4).

Reddit hands back `selftext_html` / `body_html` already rendered, and TextViewer
displays HTML through ScrollHtmlWidget -> HtmlBoxWidget -> MuPDF, so emphasis,
headings, quotes, lists and code survive to the screen.

This module sanitises: everything not on the whitelist is unwrapped, tag gone and
text kept. M.toText is the plain-text form, for rows that cannot show markup.
--]]

local M = {}

-- Tags MuPDF renders usefully on a small grayscale screen.
M.ALLOWED = {
    p = true, br = true, hr = true,
    em = true, strong = true, b = true, i = true,
    del = true, s = true, strike = true, ins = true, u = true,
    sup = true, sub = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    ul = true, ol = true, li = true,
    blockquote = true, code = true, pre = true,
    a = true, span = true, div = true,
    table = true, thead = true, tbody = true, tr = true, td = true, th = true,
}

-- Dropped along with their contents: nothing inside them is worth reading.
M.STRIP_WITH_CONTENT = { script = true, style = true, iframe = true, object = true }

--- E-ink styling: grayscale, generous line height, restrained headings. Reddit
--- h1 is just a line of emphasis in practice, so headings stay close to body size.
M.CSS = [[
body { margin: 0; padding: 0; line-height: 1.35; text-align: left; }
p { margin: 0 0 0.5em 0; }
h1, h2, h3, h4, h5, h6 { font-size: 1.1em; font-weight: bold; margin: 0.7em 0 0.3em 0; }
ul, ol { margin: 0.3em 0 0.5em 1.1em; padding: 0; }
li { margin: 0.15em 0; }
blockquote { margin: 0.4em 0 0.4em 0.5em; padding-left: 0.6em;
             border-left: 2px solid #666; font-style: italic; }
pre { margin: 0.4em 0; padding: 0.3em; background-color: #eeeeee;
      font-family: monospace; white-space: pre-wrap; }
code { font-family: monospace; }
a { text-decoration: underline; }
table { border-collapse: collapse; margin: 0.4em 0; }
td, th { border: 1px solid #999; padding: 0.15em 0.3em; }
.spoiler { border-bottom: 1px dotted #666; }
/* Bylines and other secondary text: present, but not competing with the words
   you came to read. Confirmed legible on a Paperwhite 5 at 0.8em. */
.meta { font-size: 0.8em; color: #666666; }
/* A card. Written as four longhand borders rather than the `border` shorthand:
   only border-left has been verified on this device's MuPDF, and a shorthand it
   silently ignored would take the whole box with it. Longhands are the same
   property that is already known to work. No border-radius -- MuPDF's html
   engine does not do it, and a 1px hairline is the right weight for e-ink
   anyway. */
.card { border-top: 1px solid #999999; border-bottom: 1px solid #999999;
        border-left: 1px solid #999999; border-right: 1px solid #999999;
        padding-top: 0.4em; padding-bottom: 0.4em;
        padding-left: 0.5em; padding-right: 0.5em; }
]]

local ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"',
    ["&#39;"] = "'", ["&apos;"] = "'", ["&nbsp;"] = " ",
}

function M.unescape(s)
    return (tostring(s or ""):gsub("&#?%w+;", function(e) return ENTITIES[e] or e end))
end

--- Reddit marks spoilers with class="md-spoiler-text". There is no tap-to-reveal
--- inside a rendered HTML page, so rather than hiding the text forever we mark it
--- and let the reader look away.
local function markSpoilers(html)
    return (html:gsub('<span[^>]-md%-spoiler%-text[^>]->', '<span class="spoiler">[spoiler] '))
end

--- Which hrefs survive sanitising.
---
--- A whitelist, deliberately, and it stays one: this decides what a tap can be
--- asked to do. http(s) covers links the reader wrote; the relative forms are
--- Reddit's own -- it emits `/r/kindle` and `/u/someone` as bare paths, and
--- dropping them (which the earlier `^https?://` test did) is why a subreddit
--- mention inside a comment could never be tapped. `//host/path` is Reddit's
--- protocol-relative form for the same thing.
---
--- Everything else is refused by omission: javascript:, data:, file: and any
--- scheme KOReader might one day hand to the system.
function M.allowedHref(href)
    href = tostring(href or "")
    if href:match("^https?://") then return true end
    if href:match("^//[^/]") then return true end
    -- Relative, and only the three shapes Reddit actually uses. Note the
    -- second character check: `//evil` is handled above, and a bare `/` is not
    -- a link to anywhere we can go.
    if href:match("^/r/[%w_]") or href:match("^/u/[%w_]")
            or href:match("^/user/[%w_]") or href:match("^/comments/%w") then
        return true
    end
    return false
end

--- Keep whitelisted tags (and only `href` on links); unwrap everything else.
function M.sanitize(html)
    if type(html) ~= "string" or html == "" then return "" end

    -- Reddit wraps bodies in <!-- SC_OFF --> ... <!-- SC_ON -->
    html = html:gsub("<!%-%-.-%-%->", "")

    for tag in pairs(M.STRIP_WITH_CONTENT) do
        html = html:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. "%s*>", "")
        html = html:gsub("<" .. tag .. "[^>]*/?>", "")
    end

    html = markSpoilers(html)

    html = html:gsub("<(/?)(%a[%w]*)([^>]*)>", function(slash, tag, attrs)
        local name = tag:lower()
        if not M.ALLOWED[name] then
            return ""  -- unwrap: the tag goes, its text stays
        end
        if slash == "/" then return "</" .. name .. ">" end
        if name == "a" then
            local href = attrs:match('href%s*=%s*"([^"]*)"') or attrs:match("href%s*=%s*'([^']*)'")
            if href and M.allowedHref(href) then
                return '<a href="' .. href .. '">'
            end
            return "<a>"
        end
        if name == "span" and attrs:match("spoiler") then
            return '<span class="spoiler">'
        end
        local selfclose = attrs:match("/%s*$") and "/" or ""
        return "<" .. name .. selfclose .. ">"
    end)

    -- Last, so it only ever sees the markup we are actually going to render, and
    -- only the text between its tags (§5.10).
    return require("reddle_emoji").applyToHtml(html)
end

--- A body fragment, not a document.
---
--- HtmlBoxWidget:setContent wraps whatever it is given in an <html><body> it
--- builds itself, so our own scaffold would nest a <style> inside that body,
--- where MuPDF discards it -- on the device every rule was ignored while literal
--- tags still rendered. Hence: no scaffold, and anything structural is also set
--- inline on the element (see reddle_comments).
local function fragment(body, extra_css)
    return table.concat({
        "<style>", M.CSS, extra_css or "", "</style>", body,
    })
end

--- Already-trusted markup (composed by us, parts individually sanitised).
--- Nothing here goes through sanitize, so never hand it raw Reddit HTML.
function M.rawDocument(trusted_body, extra_css)
    return fragment(trusted_body, extra_css)
end

--- Sanitised Reddit markup, ready for ScrollHtmlWidget.
function M.document(body_html, extra_css)
    return fragment(M.sanitize(body_html), extra_css)
end

--- Plain text, for the collapsed Menu rows that cannot render markup.
function M.toText(html)
    if type(html) ~= "string" or html == "" then return "" end
    local text = html
    text = text:gsub("<!%-%-.-%-%->", "")
    for tag in pairs(M.STRIP_WITH_CONTENT) do
        text = text:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. "%s*>", "")
    end
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("</p%s*>", "\n\n")
    text = text:gsub("</li%s*>", "\n")
    text = text:gsub("<li[^>]*>", "• ")
    text = text:gsub("</h%d%s*>", "\n\n")
    -- Structure that survives without markup, for KOReader builds whose TextViewer
    -- cannot render HTML (see reddle_ui_richtext).
    text = text:gsub("<blockquote[^>]*>%s*", "\n▏ ")
    text = text:gsub("</blockquote%s*>", "\n")
    text = text:gsub("<hr%s*/?>", "\n────────\n")
    text = text:gsub("<[^>]->", "")
    text = M.unescape(text)
    text = require("reddle_emoji").substitute(text)
    text = text:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- True when there is markup worth rendering as HTML rather than as text.
function M.hasMarkup(html)
    -- type check, not truthiness: KOReader's JSON decoder returns a *function*
    -- sentinel for JSON null, which is truthy and crashes on indexing.
    if type(html) ~= "string" or html == "" then return false end
    return html:match("<(%a[%w]*)") ~= nil
end

return M
