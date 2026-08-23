--[[
Reddle pairing listener (DESIGN.md §3.3c).

Runs a short-lived TCP listener on the device, serving the pairing page and
accepting the credentials the browser sends back. A one-time code shown on screen
authorises the write; nothing about the desktop is configured here.

Built on the same pieces httpinspector.koplugin uses:
  - ui/message/simpletcpserver  (LuaSocket server driven by UIManager's loop)
  - UIManager:insertZMQ / removeZMQ
  - iptables INPUT/OUTPUT rules, because Kindles firewall inbound ports

The teardown ordering below is load-bearing: getting it wrong crashed KOReader
to the home screen.

Protocol (deliberately dumb, one request, plaintext HTTP on the LAN):

    POST /pair HTTP/1.1
    Content-Type: application/json
    Content-Length: N

    {"code":"123456","client_id":"...","refresh_token":"..."}

  -> 200 "paired"      code matched, settings written, listener stops
  -> 403 "bad code"    code mismatch
  -> 400 "bad request" anything else
--]]

local Device = require("device")
local Event = require("ui/event")
local SimpleTCPServer = require("ui/message/simpletcpserver")
local UIManager = require("ui/uimanager")
local JSON = require("json")
local Identity = require("reddle_identity")
local logger = require("logger")

local Pair = {
    DEFAULT_PORT = 8888,
    TIMEOUT_SECONDS = 300, -- listener auto-stops; this is not a service
}

--- Where the pairing code and the CSRF nonce come from.
---
--- math.random is not adequate here. KOReader seeds it in frontend/random.lua
--- with os.time() -- one-second granularity, and only when something happens to
--- require that module, which Reddle never does. Either way the six-digit code
--- would be derivable by anyone who knows to within a few seconds when the
--- pairing screen was opened, and that code is the whole authorisation for
--- writing an account credential onto the device.
---
--- Overridable so the fallback path can be tested.
Pair.OPEN_URANDOM = function() return io.open("/dev/urandom", "rb") end

function Pair.randomBytes(n)
    local ok, f = pcall(Pair.OPEN_URANDOM)
    if ok and f then
        local bytes = f:read(n)
        f:close()
        if bytes and #bytes == n then return bytes end
    end
    return nil
end

--- n bytes as lowercase hex, or nil if there is no good entropy source.
function Pair.randomHex(n)
    local bytes = Pair.randomBytes(n)
    if not bytes then return nil end
    return (bytes:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

--- The six-digit code shown on screen. Falls back to math.random only if
--- /dev/urandom is unreadable, which on a Kindle should never happen -- and says
--- so in the log, because a silent downgrade of this particular value is exactly
--- the kind of thing that should not pass unnoticed.
function Pair.randomCode()
    local bytes = Pair.randomBytes(4)
    if bytes then
        local a, b, c, d = bytes:byte(1, 4)
        -- Modulo bias over 2^32 is about one part in 4295; irrelevant next to
        -- a six-digit space, and far better than a guessable seed.
        local n = ((a * 256 + b) * 256 + c) * 256 + d
        return string.format("%06d", n % 1000000)
    end
    logger.warn("Reddle: /dev/urandom unavailable, pairing code is weakly random")
    math.randomseed(os.time() + os.clock() * 1000)
    return string.format("%06d", math.random(0, 999999))
end

local function usableIP(ip)
    ip = tostring(ip or "")
    if not ip:match("^%d+%.%d+%.%d+%.%d+$") then return nil end
    if ip == "0.0.0.0" or ip:match("^127%.") then return nil end
    return ip
end

--- How the device finds the address to put on screen.
---
--- ffi/netinfo alone is not enough: it is what KOReader's own "Network info"
--- screen uses, and it came back empty on a Paperwhite 5 (reported 2026-08-20).
--- It enumerates interfaces, so it can miss one whose address arrived late, or
--- hand back an interface that carries no traffic. Each strategy is tried in
--- turn and the first usable IPv4 wins.
Pair.IP_STRATEGIES = {
    -- 1. Ask the kernel which source address it would route from. No packet is
    -- sent -- connecting a UDP socket only fixes the route locally -- and it
    -- picks the interface that can actually reach the desktop, which is exactly
    -- the question being asked. TEST-NET-3 (RFC 5737) is used as the target so
    -- nothing real is ever contacted.
    function()
        local ok, socket = pcall(require, "socket")
        if not ok or not socket.udp then return nil end
        local udp = socket.udp()
        if not udp then return nil end
        local got
        if udp:setpeername("203.0.113.1", 9) then got = udp:getsockname() end
        udp:close()
        return usableIP(got)
    end,

    -- 2. KOReader's own source, kept as a fallback for builds or platforms where
    -- the socket route lookup is unavailable.
    function()
        local ok, NetInfo = pcall(require, "ffi/netinfo")
        if not ok then return nil end
        local ok2, ifaces = pcall(function() return NetInfo:new():retrieve() end)
        if not ok2 or type(ifaces) ~= "table" then return nil end
        for _, iface in ipairs(ifaces) do
            local ip = usableIP(iface.ipv4)
            if ip then return ip end
        end
        return nil
    end,

    -- 3. Last resort: ask the system. Kindles ship busybox ifconfig; ip(8) is
    -- there on desktop Linux. Cheap to try and it costs nothing when it fails.
    function()
        local ok, pipe = pcall(io.popen, "ip -4 addr 2>/dev/null || ifconfig 2>/dev/null")
        if not ok or not pipe then return nil end
        local out = pipe:read("*a") or ""
        pipe:close()
        for ip in out:gmatch("inet%s+addr?:?%s*(%d+%.%d+%.%d+%.%d+)") do
            if usableIP(ip) then return ip end
        end
        return nil
    end,
}

--- The address the desktop should point its browser at, or nil if every
--- strategy failed (in which case the UI tells the user where to look it up).
function Pair.getLocalIP()
    for _, strategy in ipairs(Pair.IP_STRATEGIES) do
        local ok, ip = pcall(strategy)
        -- Filtered here as well as inside each strategy: an address that looks
        -- plausible but routes nowhere (127.0.0.1, 0.0.0.0) is worse than none,
        -- because the screen would claim success and the browser would hang.
        if ok then
            ip = usableIP(ip)
            if ip then return ip end
        end
    end
    return nil
end

local function firewall(action, port)
    -- action is "-A" (open) or "-D" (close). Kindle only; no-op elsewhere.
    if not Device:isKindle() then return end
    os.execute(string.format(
        "iptables %s INPUT -p tcp --dport %s -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        action, port))
    os.execute(string.format(
        "iptables %s OUTPUT -p tcp --sport %s -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        action, port))
end

local function httpResponse(code, reason, body, content_type)
    return table.concat({
        string.format("HTTP/1.1 %d %s", code, reason),
        "Content-Type: " .. (content_type or "text/plain"),
        string.format("Content-Length: %d", #body),
        "Connection: close",
        "",
        body,
    }, "\r\n")
end

--- Percent-decoding. `plus_is_space` only for form bodies: in a pasted URL a "+"
--- is a literal character, and Reddit's codes are not ours to mangle.
function Pair.urlDecode(s, plus_is_space)
    s = tostring(s or "")
    if plus_is_space then s = s:gsub("%+", " ") end
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function trim(s)
    -- Quotes and whitespace ride along with almost every paste.
    return (tostring(s or ""):gsub("^[%s\"']+", ""):gsub("[%s\"']+$", ""))
end

--- Pull code and state out of whatever the user managed to capture. Mirrors
--- extract_code in tools/reddle-bridge.sh, and the same rule decides the shape:
--- a bare code is the only input with no "=" and no "://" in it. Anything else
--- is a URL or query string and must actually carry code=, or a callback that
--- arrived without one would be mistaken for a code and sent to Reddit whole.
---
--- Accepts: redreader://rr_oauth_redir?state=..&code=..#_ , dystopia://response?..
---          state=..&code=.. , or the bare code.
--- Returns: code, state  (state is nil when the input carried none)
function Pair.extractCode(input)
    local s = trim(input)
    if s == "" then return nil end
    if not (s:find("://", 1, true) or s:find("=", 1, true)) then
        return s, nil
    end
    -- Prefixing with "&" lets one pattern match both "?code=" and a leading
    -- "code=". The class stops at "#", which drops Reddit's trailing "#_".
    local probe = "&" .. s
    local code = probe:match("[?&]code=([^&#]*)")
    local state = probe:match("[?&]state=([^&#]*)")
    if not code or code == "" then return nil end
    return trim(code), state and trim(state) or nil
end

-- SimpleTCPServer hands us the header block only and leaves the body in the
-- socket, so read it ourselves off Content-Length.
local function readBody(headers, client)
    local len = tonumber(headers:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not len or len <= 0 or len > 8192 then return nil end
    local body, err = client:receive(len)
    if not body then
        logger.warn("Reddle: pairing body read failed:", err)
        return nil
    end
    return body
end

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

--- The pairing page (DESIGN.md §3.3d). Served to whatever browser is on the
--- other end; it is the only UI the desktop side needs, which is the point --
--- no bash, no curl, no scheme handler, any OS.
---
--- The authorize URL is assembled in the browser rather than here so that
--- pasting a client ID needs no round trip to the Kindle. `state` is embedded
--- in the page: it is a CSRF nonce, not a secret, and the thing that actually
--- authorises the write is the six-digit code the user reads off the Kindle.
--- Do not "fix" this by hiding the state.
function Pair.pageHtml(opts)
    opts = opts or {}
    return string.format([[<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pair with Reddle</title>
<style>
body { font: 16px/1.5 system-ui, sans-serif; max-width: 38em; margin: 2em auto; padding: 0 1em; }
h1 { font-size: 1.4em; } h2 { font-size: 1.05em; margin-top: 2em; }
input, textarea { width: 100%%; font: inherit; padding: .5em; box-sizing: border-box; }
textarea { height: 5em; } button { font: inherit; padding: .6em 1.2em; margin-top: 1em; }
#go { display: inline-block; margin-top: .8em; padding: .6em 1.2em; background: #f0f0f0;
      border: 1px solid #999; border-radius: 4px; text-decoration: none; color: #333; }
#go[aria-disabled="true"] { opacity: .5; pointer-events: none; }
.note { color: #555; font-size: .9em; } code { background: #f4f4f4; padding: 0 .3em; }
ol.steps li { margin: .4em 0; }
h1 { display: flex; align-items: center; gap: .5em; }
.modes { display: flex; flex-wrap: wrap; gap: .8em; margin: 1.2em 0; }
.mode { flex: 1 1 15em; border: 1px solid #999; border-radius: 6px; padding: .8em;
        cursor: pointer; display: block; }
.mode b { display: block; margin: .3em 0 .2em; }
.mode:has(input:checked) { border-color: #000; border-width: 2px; padding: calc(.8em - 1px); }
.account-only[hidden] { display: none; }
h1 svg { width: 1.6em; height: 1.6em; flex: none; }
</style></head><body>
<h1><svg viewBox="0 0 128 128" aria-hidden="true"><g fill="none" stroke="currentColor"
stroke-width="7" stroke-linejoin="round" stroke-linecap="round"><path d="M24 14 H104
A14 14 0 0 1 118 28 V86 A14 14 0 0 1 104 100 H62 L38 120 V100 H24 A14 14 0 0 1 10 86
V28 A14 14 0 0 1 24 14 Z"/></g><rect x="28" y="32" width="72" height="12" rx="6"
fill="currentColor"/><g fill="none" stroke="currentColor" stroke-width="6"
stroke-linecap="round"><path d="M44 58 V84"/><path d="M60 60 H100"/><path d="M60 80 H86"/>
</g></svg>Pair with Reddle</h1>

<div class="modes">
  <label class="mode"><input type="radio" name="mode" value="anonymous" checked>
    <b>Anonymous</b>
    <span class="note">Client ID only. No Reddit account, nothing to authorize,
    no code to capture. Subreddits, comments, search, images and saving all work.
    You do not get a personalised front page or your subscriptions &mdash; those
    are account data. The request budget is whatever the client ID you use
    carries.</span></label>
  <label class="mode"><input type="radio" name="mode" value="account">
    <b>Sign in</b>
    <span class="note">Your own front page and subscriptions. Needs one extra
    step: approving at Reddit and pasting back the URL it redirects to, which
    your browser cannot open on its own.</span></label>
</div>

<h2>1. Which app's client ID?</h2>
<p class="note" id="identnote"></p>
<select id="ident">%s</select>
<p class="note" id="caveat"></p>
<div id="customwrap" hidden>
  <p class="account-only"><label>Redirect URI<br>
  <input id="curi" placeholder="myapp://callback" autocomplete="off" spellcheck="false">
  </label></p>
  <p><label>User agent<br>
  <input id="cua" placeholder="android:com.you.reddle:v1.0 (by /u/you)"
         autocomplete="off" spellcheck="false"></label>
  <span class="note">Reddit asks for a real, contactable one. Name your app and
  your username.</span></p>
</div>
<p class="note account-only">Redirect: <code id="ruri"></code></p>

<h2>2. Client ID</h2>
<p class="note">%s</p>
<input id="cid" placeholder="paste the client ID" autocomplete="off" spellcheck="false">

<div class="account-only" id="acct">
<h2>3. Authorize</h2>
<a id="go" href="#" aria-disabled="true" target="_blank" rel="noopener">Open Reddit &rarr;</a>
<p class="note">Approve, then your browser will fail to open that redirect
address. That is expected &mdash; the code you need is in the URL it could not open.</p>
<details><summary>How to get the URL</summary>
<ol class="steps">
<li>Open DevTools (<b>F12</b>) <b>before</b> approving, and pick the <b>Network</b> tab.</li>
<li>Tick <b>Preserve log</b>, or the entry disappears when the page navigates.</li>
<li>Approve. Find the <code>authorize</code> request &mdash; status <b>302</b>.</li>
<li><b>Headers &rarr; Response Headers</b>, and copy the <b>Location</b> value.</li>
</ol>
<p class="note">Safari does not show this URL at all; use Chrome, Edge or Firefox.
Do not retype the code off an error dialog &mdash; dialogs hyphenate at the line
wrap and Reddit's codes contain real hyphens, so a retyped code is silently wrong.</p>
</details>

</div>

<h2 id="laststep">3. Send it over</h2>
<form method="POST" action="/paste">
<div class="account-only">
<p class="note">Paste the URL Reddit redirected to.</p>
<textarea name="pasted" placeholder="paste the whole URL (or just the code)"
          spellcheck="false"></textarea>
</div>
<input type="hidden" name="mode" id="hmode">
<input type="hidden" name="client_id" id="hid">
<input type="hidden" name="identity" id="hident">
<input type="hidden" name="redirect_uri" id="hruri">
<input type="hidden" name="user_agent" id="hua">
<p><label>Six-digit code shown on the Kindle:<br>
<input name="code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required
       autocomplete="off"></label></p>
<button type="submit" id="send">Send to Kindle</button>
</form>
<p class="note">Reddle for Reddit — AGPL-3.0. Source:
<a href="https://github.com/DroidThug/reddle.koplugin">github.com/DroidThug/reddle.koplugin</a></p>
<script>
var REDIRECTS = %s, CAVEATS = %s, filled = false;
var cid = document.getElementById("cid"), go = document.getElementById("go"),
    ident = document.getElementById("ident"), curi = document.getElementById("curi"),
    cua = document.getElementById("cua"), wrap = document.getElementById("customwrap"),
    pasted = document.querySelector("textarea[name=pasted]"),
    modes = document.querySelectorAll("input[name=mode]");
function mode() {
  for (var i = 0; i < modes.length; i++) if (modes[i].checked) return modes[i].value;
  return "anonymous";
}
function redirectUri() {
  return ident.value === "custom" ? curi.value.trim() : (REDIRECTS[ident.value] || "");
}
function sync() {
  var anon = mode() === "anonymous";
  // Anonymous needs no redirect URI and no authorization, so the steps that
  // exist only to capture a code are hidden rather than left to be puzzled over.
  var hide = document.querySelectorAll(".account-only");
  for (var i = 0; i < hide.length; i++) hide[i].hidden = anon;
  pasted.required = !anon;
  document.getElementById("hmode").value = mode();
  document.getElementById("laststep").textContent = anon ? "3. Send it over" : "4. Paste it back";
  document.getElementById("identnote").textContent = anon
    ? "Pick the app your client ID came from."
    : "The redirect URI has to match the app your client ID came from.";
  document.getElementById("send").textContent = anon ? "Use anonymously" : "Send to Kindle";
  var custom = ident.value === "custom";
  // Prefill once, so a later edit is never clobbered.
  if (custom && !filled) { curi.value = curi.value || REDIRECTS.custom || ""; filled = true; }
  document.getElementById("caveat").textContent = CAVEATS[ident.value] || "";
  var v = cid.value.trim(), uri = redirectUri();
  wrap.hidden = !custom;
  document.getElementById("ruri").textContent = uri || "—";
  document.getElementById("hid").value = v;
  document.getElementById("hident").value = ident.value;
  document.getElementById("hruri").value = uri;
  document.getElementById("hua").value = cua.value.trim();
  // Self-registration needs a user agent of its own: without one the device
  // falls back to the shipped example, which names an app that does not exist.
  var ready = v && uri && (!custom || cua.value.trim().length > 0);
  go.setAttribute("aria-disabled", ready ? "false" : "true");
  go.href = ready ? "https://www.reddit.com/api/v1/authorize.compact?client_id="
    + encodeURIComponent(v) + "&response_type=code&state=%s&redirect_uri="
    + encodeURIComponent(uri) + "&duration=permanent&scope=%s" : "#";
}
[cid, ident, curi, cua].forEach(function (el) {
  el.addEventListener("input", sync); el.addEventListener("change", sync);
});
for (var i = 0; i < modes.length; i++) modes[i].addEventListener("change", sync);
sync();
</script>
</body></html>]],
        opts.options or "",
        esc(opts.client_id_hint or "Register one, or take the App ID from Reddit's authorization email."),
        opts.redirects or "{}", opts.caveats or "{}",
        esc(opts.state or ""), esc(opts.scope or ""))
end

--- The <option> list and the name -> redirect map the page's script needs.
--- Built here rather than in the page so reddle_identity stays the one place
--- that knows what identities exist.
function Pair.identityChoices()
    -- Nothing is preselected. Borrowing another app's registration should be a
    -- decision, not what happens if you leave a dropdown alone -- so the form
    -- cannot be submitted until something is picked.
    local options = { '<option value="" disabled selected>Choose…</option>',
        '<option value="custom">My own registration</option>' }
    local redirects, caveats = {}, {}
    for _, name in ipairs(Identity.names()) do
        local id = Identity.identities[name]
        if id then
            options[#options + 1] = string.format('<option value="%s">%s</option>',
                esc(name), esc(id.label))
            redirects[#redirects + 1] = string.format('%q:%q', name, id.redirect_uri)
            caveats[#caveats + 1] = string.format('%q:%q', name, Identity.CAVEATS[name] or "")
        end
    end
    -- "My own" starts from the redirect URI a fresh registration is told to use.
    local own = Identity.identities.own
    redirects[#redirects + 1] = string.format('%q:%q', "custom", own and own.redirect_uri or "")
    return table.concat(options),
        "{" .. table.concat(redirects, ",") .. "}",
        "{" .. table.concat(caveats, ",") .. "}"
end

function Pair:isRunning()
    return self.server ~= nil
end

--- Start listening.
--   on_paired(client_id, refresh_token)  -- POST /pair, the desktop bridge
--   on_authorized(client_id, auth_code)  -- POST /paste, the served page
--
-- on_authorized gets an authorization code, not a token: the exchange is a TLS
-- round trip and must NOT happen in onRequest, which runs inside
-- UIManager:processZMQs with the polled socket still open. The caller does it
-- after the listener has stopped. See the comment on stop().
--
-- Returns ok, ip, port, code  (or false, err)
function Pair:start(port, on_paired, on_authorized, on_anonymous)
    if self:isRunning() then self:stop() end
    self.port = port or self.DEFAULT_PORT
    self.code = Pair.randomCode()
    -- A CSRF nonce tying the pasted callback to the link this page handed out.
    -- Not a secret, and not what authorises the write -- self.code is.
    self.state = Pair.randomHex(16) or string.format("%08x%08x",
        math.random(0, 2 ^ 31 - 1), math.random(0, 2 ^ 31 - 1))
    self.on_paired = on_paired
    self.on_authorized = on_authorized
    self.on_anonymous = on_anonymous

    firewall("-A", self.port)
    self.server = SimpleTCPServer:new{
        host = "*",
        port = self.port,
        receiveCallback = function(data, client) return self:onRequest(data, client) end,
    }
    local ok, err = self.server:start()
    if not ok then
        firewall("-D", self.port)
        self.server = nil
        return false, err
    end
    self.mq = UIManager:insertZMQ(self.server)

    self.timeout_task = function() self:stop() end
    UIManager:scheduleIn(self.TIMEOUT_SECONDS, self.timeout_task)

    return true, self.getLocalIP(), self.port, self.code
end

--- Teardown must never throw: UIManager:processZMQs runs unprotected, so an error
--- here takes KOReader down to the Kindle home screen rather than showing a dialog.
--- Order matters too -- deregister from the poll loop *before* closing the socket,
--- or the next waitEvent call lands on a closed socket.
function Pair:stop()
    if self.timeout_task then
        pcall(function() UIManager:unschedule(self.timeout_task) end)
        self.timeout_task = nil
    end
    if not self.server then return end

    local server, mq, port = self.server, self.mq, self.port
    -- Clear our own state first, so a re-entrant stop() (the pairing dialog's
    -- dismiss_callback fires one too) is a no-op instead of a double close.
    self.server, self.mq, self.code, self.state = nil, nil, nil, nil

    if mq then
        local ok, err = pcall(function() UIManager:removeZMQ(mq) end)
        if not ok then logger.warn("Reddle: removeZMQ failed:", err) end
    end
    local ok, err = pcall(function() server:stop() end)
    if not ok then logger.warn("Reddle: server stop failed:", err) end
    pcall(function() firewall("-D", port) end)
end

--- application/x-www-form-urlencoded -> table. Values are percent-decoded with
--- "+" as space, which is correct for a form body and wrong for a bare URL --
--- hence the flag on urlDecode.
local RESULT_PAGE = [[<!doctype html><html><head><meta charset="utf-8">
<title>Sent</title><style>body{font:16px/1.5 system-ui,sans-serif;max-width:34em;
margin:4em auto;padding:0 1em}</style></head><body>
<h1>%s</h1><p>%s</p></body></html>]]

--- POST /paste -- the served page's form (DESIGN.md §3.3d).
---
--- Ends by handing an *authorization code* to on_authorized and returning. The
--- token exchange deliberately does not happen here: onRequest runs inside
--- UIManager:processZMQs, unprotected, with this socket still being polled, so a
--- TLS round trip on this path risks taking KOReader down the way a botched
--- teardown once did. The browser is told "sent, look at your Kindle" and the
--- device finishes the job on its own time.
function Pair:onPaste(data, client, reply)
    local function fail(code, reason, title, detail)
        reply(code, reason, string.format(RESULT_PAGE, title, detail),
            "text/html; charset=utf-8")
        return Event:new("InputEvent")
    end

    local form = Pair.parseForm(readBody(data, client) or "")

    -- Never log the form: it carries a client ID and an authorization code.
    if form.code ~= self.code then
        logger.warn("Reddle: paste rejected, code mismatch")
        return fail(403, "Forbidden", "Wrong code",
            "That is not the six-digit code on the Kindle screen.")
    end

    local client_id = trim(form.client_id or "")
    if client_id == "" then
        return fail(400, "Bad Request", "No client ID", "Paste a client ID in step 1.")
    end

    -- Which app the client ID belongs to. This must survive to the exchange:
    -- Reddit checks redirect_uri against the one the code was issued for, so an
    -- identity chosen here and ignored there fails with a bare "invalid_grant".
    local identity = {
        identity = trim(form.identity or ""),
        redirect_uri = trim(form.redirect_uri or ""),
        user_agent = trim(form.user_agent or ""),
    }
    if identity.identity == "" then identity = nil
    else
        local ok, why = Identity.apply(identity)
        if not ok then
            -- Includes the placeholder user agent: reddle_identity refuses it,
            -- and the page is not the only way a form arrives here.
            return fail(400, "Bad Request", "Bad identity", tostring(why))
        end
    end

    -- Anonymous: a client ID is the whole credential. There is no authorization
    -- code to check a state against, because nothing was ever authorized.
    if trim(form.mode or "") == "anonymous" then
        reply(200, "OK", string.format(RESULT_PAGE, "Sent to the Kindle",
            "Reddle is set up for anonymous reading. You can close this tab."),
            "text/html; charset=utf-8")
        if self.on_anonymous then
            local on_anonymous = self.on_anonymous
            UIManager:scheduleIn(0.5, function()
                self:stop()
                local ok, err = pcall(on_anonymous, client_id, identity)
                if not ok then logger.warn("Reddle: on_anonymous failed:", err) end
            end)
        end
        return Event:new("InputEvent")
    end

    local auth_code, got_state = Pair.extractCode(form.pasted)
    if not auth_code then
        return fail(400, "Bad Request", "No code found",
            "That did not contain a code= value. Paste the whole Location URL.")
    end
    -- A paste carrying no state at all is the user acting deliberately (they may
    -- have copied the code alone), so it passes. A wrong one never does.
    if got_state and self.state and got_state ~= self.state then
        logger.warn("Reddle: paste rejected, state mismatch")
        return fail(403, "Forbidden", "State mismatch",
            "That code came from a different authorization. Reload and start again.")
    end

    reply(200, "OK", string.format(RESULT_PAGE, "Sent to the Kindle",
        "Finishing sign-in on the device — check its screen. You can close this tab."),
        "text/html; charset=utf-8")

    if self.on_authorized then
        -- Defer generously: nextTick can still land inside the UIManager pass
        -- that is polling this socket. Same reasoning as the /pair path.
        local on_authorized = self.on_authorized
        UIManager:scheduleIn(0.5, function()
            self:stop()
            local ok, err = pcall(on_authorized, client_id, auth_code, identity)
            if not ok then logger.warn("Reddle: on_authorized failed:", err) end
        end)
    end
    return Event:new("InputEvent")
end

function Pair.parseForm(body)
    local out = {}
    for pair_str in tostring(body or ""):gmatch("[^&]+") do
        local k, v = pair_str:match("^([^=]*)=(.*)$")
        if k and k ~= "" then out[Pair.urlDecode(k, true)] = Pair.urlDecode(v, true) end
    end
    return out
end

function Pair:onRequest(data, client)
    local method, path = data:match("^(%a+)%s+(%S+)")
    local function reply(code, reason, body, ctype)
        self.server:send(httpResponse(code, reason, body, ctype), client)
    end
    path = tostring(path or ""):gsub("%?.*$", "")

    -- The page itself is unauthenticated: it has to be fetchable before the user
    -- has typed anything. It hands out no credential -- the six-digit code is
    -- checked on the way back in.
    if method == "GET" and (path == "/" or path == "/index.html") then
        local options, redirects, caveats = Pair.identityChoices()
        reply(200, "OK", Pair.pageHtml{
            state = self.state,
            scope = Identity.SCOPE,
            options = options,
            redirects = redirects,
            caveats = caveats,
            client_id_hint = "Take the App ID from Reddit's authorization email, "
                .. "or register your own app at reddit.com/prefs/apps.",
        }, "text/html; charset=utf-8")
        return Event:new("InputEvent")
    end

    if method == "POST" and path == "/paste" then
        return self:onPaste(data, client, reply)
    end

    if method ~= "POST" or path ~= "/pair" then
        reply(400, "Bad Request", "bad request")
        return Event:new("InputEvent")
    end

    local body = readBody(data, client)
    local ok, payload = pcall(JSON.decode, body or "")
    if not ok or type(payload) ~= "table" then
        reply(400, "Bad Request", "bad request")
        return Event:new("InputEvent")
    end

    -- Never log the payload: it carries a full account credential.
    if payload.code ~= self.code then
        logger.warn("Reddle: pairing rejected, code mismatch")
        reply(403, "Forbidden", "bad code")
        return Event:new("InputEvent")
    end

    if type(payload.client_id) ~= "string" or type(payload.refresh_token) ~= "string" then
        reply(400, "Bad Request", "bad request")
        return Event:new("InputEvent")
    end

    reply(200, "OK", "paired")
    if self.on_paired then
        -- Defer, and defer generously: nextTick can still land inside the same
        -- UIManager pass that is polling this very socket. A short delay lets
        -- processZMQs finish with it before we close it underneath.
        local client_id, refresh_token = payload.client_id, payload.refresh_token
        local on_paired = self.on_paired
        UIManager:scheduleIn(0.5, function()
            self:stop()
            -- Never let a callback error escape into the event loop.
            local ok, err = pcall(on_paired, client_id, refresh_token)
            if not ok then logger.warn("Reddle: on_paired failed:", err) end
        end)
    end
    return Event:new("InputEvent")
end

return Pair
