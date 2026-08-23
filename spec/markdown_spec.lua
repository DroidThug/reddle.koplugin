local Md = require("reddle_markdown")

describe("reddle_markdown", function()

    describe("emphasis", function()
        it("removes markers we cannot render on e-ink", function()
            assert_equal("bold", Md.toText("**bold**"))
            assert_equal("italic", Md.toText("*italic*"))
            assert_equal("both", Md.toText("***both***"))
            assert_equal("under", Md.toText("__under__"))
            assert_equal("struck", Md.toText("~~struck~~"))
            assert_equal("code", Md.toText("`code`"))
        end)

        it("keeps the surrounding sentence intact", function()
            assert_equal("a bold word here", Md.toText("a **bold** word here"))
        end)

        it("hides spoilers rather than revealing them", function()
            assert_equal("the answer is [spoiler]", Md.toText("the answer is >!42!<"))
        end)

        it("drops superscript carets", function()
            assert_equal("note here", Md.toText("^(note) here"))
            assert_equal("edit and more", Md.toText("^edit and more"))
        end)
    end)

    describe("links", function()
        it("keeps the text and says where it goes", function()
            assert_equal("the guide (kindlemodding.org)",
                Md.toText("[the guide](https://kindlemodding.org/jailbreaking/)"))
        end)

        it("does not repeat a host the text already names", function()
            assert_equal("kindlemodding.org", Md.toText("[kindlemodding.org](https://kindlemodding.org/)"))
        end)

        it("falls back to the URL when there is no text", function()
            assert_equal("https://example.com/x", Md.toText("[](https://example.com/x)"))
        end)

        it("leaves bare URLs alone", function()
            assert_equal("see https://example.com/x now", Md.toText("see https://example.com/x now"))
        end)
    end)

    describe("structure", function()
        it("marks quotes with a rule, and nests them", function()
            assert_equal("▏ quoted", Md.toText("> quoted"))
            assert_equal("▏ ▏ deeper", Md.toText(">> deeper"))
        end)

        it("normalises bullets", function()
            assert_equal("• one\n• two", Md.toText("- one\n* two"))
        end)

        it("keeps numbered lists numbered", function()
            assert_equal("1. first\n2. second", Md.toText("1. first\n2. second"))
        end)

        it("keeps heading text but drops the hashes", function()
            assert_equal("Title", Md.toText("## Title"))
        end)

        it("preserves indented code blocks verbatim", function()
            assert_equal("  local x = 1", Md.toText("    local x = 1"))
        end)

        it("preserves fenced code blocks and drops the fences", function()
            assert_equal("  a = 1\n  b = 2", Md.toText("```\na = 1\nb = 2\n```"))
        end)

        it("does not treat a bullet inside a fence as a bullet", function()
            assert_equal("  - not a list", Md.toText("```\n- not a list\n```"))
        end)

        it("turns horizontal rules into something visible", function()
            assert_equal(Md.RULE, Md.toText("---"))
        end)

        it("degrades tables to spaced text", function()
            assert_match("a  b", Md.toText("| a | b |"))
        end)
    end)

    describe("whitespace", function()
        it("collapses the blank lines Reddit is fond of", function()
            assert_equal("a\n\nb", Md.toText("a\n\n\n\n\nb"))
        end)

        it("trims leading and trailing blank lines", function()
            assert_equal("body", Md.toText("\n\n  body  \n\n"))
        end)

        it("returns empty string for empty input", function()
            assert_equal("", Md.toText(""))
            assert_equal("", Md.toText(nil))
        end)
    end)

    describe("entities", function()
        it("decodes what Reddit escapes", function()
            assert_equal("a & b < c > d", Md.toText("a &amp; b &lt; c &gt; d"))
            assert_equal('say "hi"', Md.toText("say &quot;hi&quot;"))
            assert_equal("it's", Md.toText("it&#39;s"))
        end)

        it("strips the zero-width space Reddit injects", function()
            assert_equal("text", Md.toText("&#x200B;text"))
        end)
    end)

    describe("host", function()
        it("strips scheme and www", function()
            assert_equal("reddit.com", Md.host("https://www.reddit.com/r/kindle"))
            assert_equal("i.redd.it", Md.host("https://i.redd.it/abc.jpg"))
        end)

        it("returns nil for a non-URL", function()
            assert_nil(Md.host("not a url"))
        end)
    end)

    describe("preview", function()
        it("keeps the first n lines and marks the cut", function()
            local p = Md.preview("one\ntwo\nthree\nfour", 2)
            assert_equal("one\ntwo …", p)
        end)

        it("leaves short text alone", function()
            assert_equal("one\ntwo", Md.preview("one\ntwo", 4))
        end)
    end)

    describe("a realistic comment", function()
        it("survives everything at once", function()
            local md = "I **finally** got it working!\n\n" ..
                "> which firmware?\n\n" ..
                "5.16.4 — see [the guide](https://kindlemodding.org/x) ^(worked first try)\n\n" ..
                "- install KUAL\n- copy the plugin\n\n" ..
                "    cp -r reddle.koplugin /mnt/us/\n"
            local out = Md.toText(md)
            assert_match("I finally got it working!", out)
            assert_match("▏ which firmware", out)
            assert_match("the guide %(kindlemodding%.org%)", out)
            assert_match("worked first try", out)
            assert_match("• install KUAL", out)
            assert_match("  cp %-r reddle%.koplugin", out)
            assert_false(out:find("%*%*") ~= nil, "no leftover markers")
        end)
    end)
end)
