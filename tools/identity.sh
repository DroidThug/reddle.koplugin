# Shared by the desktop tools: read the active identity out of
# reddle_identity.lua so the Mac and the Kindle can never
# disagree about what Reddit sees. Source this, don't execute it.
#
# Exports: REDDLE_UA, REDDLE_REDIRECT_URI, REDDLE_IDENTITY
# Override either by setting it before sourcing.

reddle_identity_load() {
    local root="$1"
    local lua_file="${root}/reddle_identity.lua"
    [[ -f "$lua_file" ]] || { echo "missing ${lua_file}" >&2; return 1; }

    # REDDLE_IDENTITY selects which identity to read. It matters now that the
    # compiled-in default is `own` rather than a borrowed registration: someone
    # using the bridge with RedReader's client ID has to say so, and would
    # otherwise silently authorize against http://localhost:8080 and get an
    # unexplained invalid_grant.
    local want="${REDDLE_IDENTITY:-}"

    # Preferred: ask Lua, so the shell and the device evaluate the same code.
    if command -v luajit >/dev/null 2>&1 || command -v lua >/dev/null 2>&1; then
        local lua_bin; lua_bin="$(command -v luajit || command -v lua)"
        local out
        out="$("$lua_bin" -e '
            package.path = "'"${root}"'/?.lua;" .. package.path
            local I = require("reddle_identity")
            local want = "'"${want}"'"
            if want ~= "" then
                if not I.identities[want] then
                    io.stderr:write("unknown REDDLE_IDENTITY: ", want, "\n")
                    os.exit(1)
                end
                I.active = want
            end
            io.write(I.active, "\n", I.userAgent(), "\n", I.redirectUri(), "\n")
        ' 2>/dev/null)"
        if [[ -n "$out" ]]; then
            REDDLE_IDENTITY="$(sed -n 1p <<<"$out")"
            REDDLE_UA="$(sed -n 2p <<<"$out")"
            REDDLE_REDIRECT_URI="$(sed -n 3p <<<"$out")"
        fi
    fi

    # Fallback for machines with no Lua: parse the active identity's block.
    if [[ -z "${REDDLE_UA:-}" ]]; then
        local active
        active="${want:-$(sed -n 's/^M\.active = "\([^"]*\)".*/\1/p' "$lua_file" | head -1)}"
        REDDLE_IDENTITY="$active"
        REDDLE_UA="$(sed -n "/^    ${active} = {/,/^    },/p" "$lua_file" \
            | sed -n 's/.*user_agent = "\([^"]*\)".*/\1/p' | head -1)"
        REDDLE_REDIRECT_URI="$(sed -n "/^    ${active} = {/,/^    },/p" "$lua_file" \
            | sed -n 's/.*redirect_uri = "\([^"]*\)".*/\1/p' | head -1)"
    fi

    [[ -n "${REDDLE_UA:-}" && -n "${REDDLE_REDIRECT_URI:-}" ]] || {
        echo "could not read identity from ${lua_file}" >&2; return 1; }

    export REDDLE_IDENTITY REDDLE_UA REDDLE_REDIRECT_URI
}
