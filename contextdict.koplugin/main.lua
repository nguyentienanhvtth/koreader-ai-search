--[[--
AI search (context dictionary) for KOReader.

When a word is looked up, the word plus the text around it is POSTed as JSON
to a user-configured API, and the answer (English + Vietnamese meaning in
this context) is shown as the FIRST result "tab" of the dictionary popup,
before the regular dictionaries. A "Dictionary | AI search" button row lets
you switch between them. Multi-word selections get an "AI search" button in
the highlight menu.

See README.md for the API request/response contract.
]]

local DictQuickLookup = require("ui/widget/dictquicklookup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local SETTINGS_KEY = "contextdict"
local RESULT_NAME = "AI search"
local CACHE_MAX = 60

local DEFAULTS = {
    api_url = "",
    api_key = "",
    auto_lookup = true, -- fetch AI on every dictionary lookup and show it first
    context_words = 40, -- words taken on each side of the selection
    timeout = 30,       -- seconds
    target_lang = "vi",
}

-- Optional config.lua next to this file: { stamp = "...", api_url = "...", api_key = "..." }.
-- Its values are copied into the settings once per stamp, so a new config
-- can be shipped by just copying the plugin folder, while edits made later
-- in the menu are kept.
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."

local RESULT_CSS = [[
.hw { font-size: 1.45em; font-weight: bold; margin: 0.1em 0 0 0; }
.sub { color: #555; margin: 0.1em 0 0.5em 0; }
.lbl { font-weight: bold; margin: 0.7em 0 0.15em 0; }
p { margin: 0.15em 0; }
.why { color: #555; font-size: 0.9em; }
hr { border: 0; border-top: 1px solid #999; margin: 0.8em 0 0.2em 0; }
.ex { font-style: italic; }
.foot { color: #666; font-size: 0.85em; margin-top: 0.9em; }
]]

-- JSON nulls/numbers/etc. are ignored: only non-empty strings are kept.
local function str(v)
    if type(v) == "string" and v:match("%S") then
        return v
    end
end

local function esc(s)
    return (util.htmlEscape(s))
end

-- Collapses whitespace and turns typographic quotes/ellipsis into ASCII, so
-- that the byte-based Lua patterns below can work on them.
local function oneLine(s)
    s = s:gsub("%s+", " ")
    s = s:gsub("“", '"'):gsub("”", '"'):gsub("‘", "'"):gsub("’", "'"):gsub("…", "...")
    return s
end

-- Best-effort extraction of the sentence containing the selection
-- (arguments must already be passed through oneLine()).
local function extractSentence(before, selected, after)
    local b = before or ""
    local last_end
    for pos in b:gmatch("[%.!%?][\"'%)]*%s()") do
        last_end = pos
    end
    if last_end then
        b = b:sub(last_end)
    end
    local a = after or ""
    local stop = a:find("[%.!%?]")
    if stop then
        local closing = a:match("^[\"'%)]*", stop + 1) or ""
        a = a:sub(1, stop + #closing)
    end
    return util.trim(b .. selected .. a)
end

local function messageEntry(word, text)
    return {
        dict = RESULT_NAME,
        word = word,
        definition = '<p class="foot">' .. esc(text) .. '</p>',
        is_html = true,
        css = RESULT_CSS,
        contextdict_pending = true,
    }
end

local ContextDict = WidgetContainer:extend{
    name = "contextdict",
    is_doc_only = true,
}

function ContextDict:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY, {})
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then
            self.settings[k] = v
        end
    end
    self:applyBundledConfig()
    self.cache = {}
    self.cache_order = {}

    self.ui.menu:registerToMainMenu(self)
    self:registerDictButtons()
    self:registerHighlightButton()
    self:hookShowDict()
end

function ContextDict:applyBundledConfig()
    local ok, cfg = pcall(dofile, PLUGIN_DIR .. "/config.lua")
    if not ok or type(cfg) ~= "table" or not str(cfg.stamp) then return end
    if self.settings.config_stamp == cfg.stamp then return end
    if str(cfg.api_url) then self.settings.api_url = cfg.api_url end
    if type(cfg.api_key) == "string" then self.settings.api_key = cfg.api_key end
    self.settings.config_stamp = cfg.stamp
    self:saveSettings()
    logger.info("ContextDict: applied bundled config", cfg.stamp)
end

function ContextDict:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

--------------------------------------------------------------------------
-- Dictionary popup integration
--------------------------------------------------------------------------

-- Wrap this book's ReaderDictionary:showDict so that every popup it opens
-- gets the AI result inserted as its first tab.
function ContextDict:hookShowDict()
    local rd = self.ui.dictionary
    if not (rd and rd.showDict) then return end
    local orig_showDict = rd.showDict
    rd.showDict = function(rd_self, word, results, ...)
        orig_showDict(rd_self, word, results, ...)
        if not self.settings.auto_lookup or not str(self.settings.api_url) then return end
        if rd_self.is_wiki or not (results and results[1]) or results.lookup_cancelled then return end
        local popup = rd_self.dict_window
        if not popup or popup.is_wiki then return end
        local ctx = self:getContext(word)
        -- Run on the next tick, once the popup is in the window stack.
        UIManager:nextTick(function()
            if not UIManager:isWidgetShown(popup) then return end
            if not NetworkMgr:isOnline() then
                self:setPopupEntry(popup, messageEntry(word,
                    "Chưa có mạng. Bật Wi-Fi rồi bấm “AI search” để tra."), false)
                return
            end
            self:fillPopup(popup, word, ctx)
        end)
    end
end

-- Puts `entry` as the AI tab (index 1) of the popup; shows it if `show`.
function ContextDict:setPopupEntry(popup, entry, show)
    local current = popup.dict_index
    local inserted = false
    if popup._contextdict_index then
        popup.results[popup._contextdict_index] = entry
    else
        table.insert(popup.results, 1, entry)
        popup._contextdict_index = 1
        inserted = true
        -- The "(query : word)" footer only makes sense on a dictionary result.
        popup.addQueryWordToResult = function() end
    end
    if show or (not inserted and current == popup._contextdict_index) then
        popup:changeDictionary(popup._contextdict_index)
    elseif inserted then
        -- Shifted by the insert: keep showing the same dictionary result.
        popup:changeDictionary(current + 1)
    else
        -- Only the hidden AI tab changed; refresh the "n / m" counter.
        popup:changeDictionary(current)
    end
end

-- Shows a loading tab, fetches (blocking), then shows the result.
function ContextDict:fillPopup(popup, word, ctx)
    local cached = self.cache[self:cacheKey(word, ctx)]
    if cached then
        self:setPopupEntry(popup, self:makeResultEntry(word, ctx, cached), true)
        return
    end
    self:setPopupEntry(popup, messageEntry(word, "Đang tra AI…"), true)
    UIManager:forceRePaint()
    local entry = self:fetchEntry(word, ctx)
    if UIManager:isWidgetShown(popup) then
        self:setPopupEntry(popup, entry, popup.dict_index == popup._contextdict_index)
    end
end

function ContextDict:registerDictButtons()
    if not (self.ui.dictionary and self.ui.dictionary.addToDictButtons) then
        logger.warn("ContextDict: this KOReader version has no dictionary button API")
        return
    end
    -- Two conditional buttons in one row, acting like tabs. Ids sort so that
    -- "Dictionary" comes first. Labels are static: Button calls text_func()
    -- without the popup, despite the API docs.
    local show = function(dict_popup)
        return not dict_popup.is_wiki and not dict_popup._contextdict_only
    end
    self.ui.dictionary:addToDictButtons{
        id = "contextdict_1_dict",
        text = "Dictionary",
        conditional = true,
        row_group = "contextdict_tabs",
        show_func = show,
        callback = function(dict_popup)
            local ai = dict_popup._contextdict_index
            local target = (ai == 1) and 2 or 1
            if dict_popup.results[target] then
                dict_popup:changeDictionary(target)
            end
        end,
    }
    self.ui.dictionary:addToDictButtons{
        id = "contextdict_2_ai",
        text = "AI search",
        conditional = true,
        row_group = "contextdict_tabs",
        show_func = show,
        callback = function(dict_popup)
            self:onAiButton(dict_popup)
        end,
        hold_callback = function()
            self:editApiUrl()
        end,
    }
end

function ContextDict:onAiButton(dict_popup)
    local idx = dict_popup._contextdict_index
    local entry = idx and dict_popup.results[idx]
    if entry and not entry.contextdict_pending then
        dict_popup:changeDictionary(idx)
        return
    end
    if not str(self.settings.api_url) then
        self:showNoApiMessage()
        return
    end
    local word = dict_popup.word or dict_popup.lookupword
    if not str(word) then return end
    local ctx = self:getContext(word)
    local run = function()
        if UIManager:isWidgetShown(dict_popup) then
            self:fillPopup(dict_popup, word, ctx)
        end
    end
    if NetworkMgr:willRerunWhenOnline(run) then
        return -- Wi-Fi is being turned on; `run` will be called once online.
    end
    run()
end

function ContextDict:registerHighlightButton()
    if not self.ui.highlight then return end
    -- "11_9_" sorts after the built-in 11_* buttons and before "12_search".
    self.ui.highlight:addToHighlightDialog("11_9_contextdict_ai", function(this)
        return {
            text = "AI search",
            enabled = this.selected_text ~= nil and this.selected_text.text ~= nil,
            callback = function()
                self:onHighlightButton(this)
            end,
        }
    end)
end

function ContextDict:onHighlightButton(highlight)
    local selected_text = highlight.selected_text
    if not (selected_text and selected_text.text) then return end
    if not str(self.settings.api_url) then
        self:showNoApiMessage()
        return
    end
    local text = util.cleanupSelectedText(selected_text.text)
    local ctx = self:getContext(nil)
    -- Same screen-box conversion ReaderHighlight:lookupDict() does, so the
    -- popup is placed near the selection rather than over it.
    local word_boxes
    pcall(function()
        if selected_text.sboxes and highlight.hold_pos then
            local boxes = {}
            for i, sbox in ipairs(selected_text.sboxes) do
                boxes[i] = highlight.view:pageToScreenTransform(highlight.hold_pos.page, sbox)
            end
            word_boxes = boxes
        end
    end)
    highlight:onClose(true) -- close the menu, keep the selection visible
    local run = function()
        local info = InfoMessage:new{ text = "Đang tra AI “" .. text .. "”…", dismissable = false }
        UIManager:show(info)
        UIManager:forceRePaint()
        local entry = self:fetchEntry(text, ctx)
        UIManager:close(info)
        UIManager:show(DictQuickLookup:new{
            ui = self.ui,
            highlight = highlight,
            dialog = self.ui.dictionary and self.ui.dictionary.dialog,
            word = text,
            results = { entry },
            word_boxes = word_boxes,
            _contextdict_only = true,
            _contextdict_index = 1,
            addQueryWordToResult = function() end,
            html_dictionary_link_tapped_callback = function() end,
        })
    end
    if NetworkMgr:willRerunWhenOnline(run) then return end
    run()
end

function ContextDict:showNoApiMessage()
    UIManager:show(InfoMessage:new{
        text = "Chưa đặt địa chỉ API.\n\nVào menu Tìm kiếm (kính lúp) → AI search → Địa chỉ API.",
    })
end

--------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------

-- Returns { selected, before, after, sentence } from the current book
-- selection, or nil when there is no usable selection. When `word` is
-- given, the selection must contain it (a word looked up from inside a
-- dictionary definition is not in the book, so the book context would be
-- misleading).
function ContextDict:getContext(word)
    local hl = self.ui.highlight
    if not (hl and hl.selected_text and hl.selected_text.text) then return end
    local selected_raw = hl.selected_text.text
    local selected = util.cleanupSelectedText(selected_raw)
    if word then
        local w, s = word:lower(), selected:lower()
        if not s:find(w, 1, true) and not w:find(s, 1, true) then
            return
        end
    end
    local ok, before, after = pcall(hl.getSelectedWordContext, hl, self.settings.context_words)
    if not ok or (not before and not after) then return end
    before, after = oneLine(before or ""), oneLine(after or "")
    return {
        selected = oneLine(selected),
        before = before,
        after = after,
        sentence = extractSentence(before, oneLine(selected_raw), after),
    }
end

--------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------

function ContextDict:buildPayload(word, ctx)
    local props = self.ui.doc_props or {}
    local authors = props.authors
    if type(authors) == "string" then
        authors = authors:gsub("\n", ", ")
    else
        authors = nil
    end
    local payload = {
        word = word,
        target_lang = self.settings.target_lang,
    }
    local book = {
        title = str(props.display_title) or str(props.title),
        author = authors,
        language = str(props.language),
    }
    if next(book) then
        payload.book = book
    end
    if ctx then
        payload.selected_text = ctx.selected
        payload.sentence = ctx.sentence
        payload.context_before = ctx.before
        payload.context_after = ctx.after
    end
    return payload
end

-- Returns true, decoded_table  or  false, error_message
function ContextDict:callApi(payload)
    local url = self.settings.api_url
    local body = JSON.encode(payload)
    local headers = {
        ["Content-Type"] = "application/json; charset=utf-8",
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
        ["Content-Length"] = tostring(#body),
    }
    if str(self.settings.api_key) then
        headers["Authorization"] = "Bearer " .. self.settings.api_key
    end
    local sink = {}
    socketutil:set_timeout(math.min(15, self.settings.timeout), self.settings.timeout)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    local content = table.concat(sink)
    if resp_headers == nil then
        logger.warn("ContextDict: network error", code, status)
        return false, "Lỗi mạng hoặc hết thời gian chờ (" .. tostring(status or code) .. ")"
    end
    if code ~= 200 then
        logger.warn("ContextDict: HTTP", code, content)
        local ok, decoded = pcall(JSON.decode, content)
        local msg = ok and type(decoded) == "table" and str(decoded.error)
        return false, "API trả về lỗi " .. tostring(code) .. (msg and (": " .. msg) or "")
    end
    local ok, decoded = pcall(JSON.decode, content)
    if not ok or type(decoded) ~= "table" then
        logger.warn("ContextDict: invalid JSON", content)
        return false, "API trả về dữ liệu không phải JSON hợp lệ."
    end
    return true, decoded
end

function ContextDict:cacheKey(word, ctx)
    return word .. "\0" .. (ctx and ctx.sentence or "")
end

function ContextDict:cachePut(key, value)
    if not self.cache[key] then
        table.insert(self.cache_order, key)
        if #self.cache_order > CACHE_MAX then
            self.cache[table.remove(self.cache_order, 1)] = nil
        end
    end
    self.cache[key] = value
end

-- Blocking fetch. Always returns a popup result entry: the explanation, or
-- an error message entry (marked pending, so "AI search" retries it).
function ContextDict:fetchEntry(word, ctx)
    local key = self:cacheKey(word, ctx)
    local res = self.cache[key]
    if not res then
        local ok, res_or_err = self:callApi(self:buildPayload(word, ctx))
        if not ok then
            return messageEntry(word, "Không lấy được giải nghĩa. " .. res_or_err ..
                "\nBấm “AI search” để thử lại.")
        end
        res = res_or_err
        self:cachePut(key, res)
    end
    return self:makeResultEntry(word, ctx, res)
end

--------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------

function ContextDict:makeResultEntry(word, ctx, res)
    return {
        dict = RESULT_NAME,
        word = str(res.lemma) or str(res.word) or word,
        definition = self:renderHtml(word, ctx, res),
        is_html = true,
        css = RESULT_CSS,
        lang = "vi",
    }
end

function ContextDict:renderHtml(word, ctx, res)
    -- The API may return ready-made HTML and skip the structured fields.
    if str(res.html) then
        return res.html
    end

    local h = {}
    local function add(s) h[#h + 1] = s end
    local function section(label, value, class)
        if str(value) then
            add('<div class="lbl">' .. esc(label) .. '</div><p' ..
                (class and (' class="' .. class .. '"') or '') .. '>' .. esc(value) .. '</p>')
        end
    end

    add('<div class="hw">' .. esc(str(res.lemma) or str(res.word) or word) .. '</div>')
    local sub = {}
    if str(res.part_of_speech) then
        local pos = res.part_of_speech
        sub[#sub + 1] = esc(pos:sub(1, 1):upper() .. pos:sub(2))
    end
    if str(res.ipa) then sub[#sub + 1] = esc(res.ipa) end
    sub[#sub + 1] = ctx and "Contextual meaning" or "General meaning"
    add('<div class="sub">' .. table.concat(sub, " · ") .. '</div>')

    local level = str(res.cefr_level)
    section(level and ("English (" .. level .. ")") or "English", res.meaning_en)
    section("Tiếng Việt", res.meaning_vi)
    if str(res.sentence_vi) or str(res.explanation_vi) then
        add('<div class="lbl">Trong ngữ cảnh này</div>')
        if str(res.sentence_vi) then add('<p>' .. esc(res.sentence_vi) .. '</p>') end
        if str(res.explanation_vi) then add('<p class="why">' .. esc(res.explanation_vi) .. '</p>') end
    end

    local examples = type(res.examples) == "table" and res.examples or {}
    local shown_hr = false
    for _, ex in ipairs(examples) do
        if type(ex) == "table" and str(ex.en) then
            if not shown_hr then
                add('<hr/><div class="lbl">Example</div>')
                shown_hr = true
            end
            add('<p class="ex">' .. esc(ex.en) .. '</p>')
            if str(ex.vi) then add('<p>' .. esc(ex.vi) .. '</p>') end
        end
    end

    if type(res.other_meanings) == "table" and #res.other_meanings > 0 then
        local others = {}
        for _, m in ipairs(res.other_meanings) do
            if str(m) then others[#others + 1] = esc(m) end
        end
        if #others > 0 then
            add('<p class="foot">Nghĩa khác: ' .. table.concat(others, "; ") .. '</p>')
        end
    end
    add('<p class="foot">' .. (ctx and "Context-aware explanation" or
        "Không lấy được ngữ cảnh trong sách: giải nghĩa chung.") .. '</p>')
    return table.concat(h, "\n")
end

--------------------------------------------------------------------------
-- Settings menu
--------------------------------------------------------------------------

function ContextDict:editText(title, key, hint, done)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self.settings[key] or "",
        input_hint = hint,
        buttons = {{
            {
                text = "Hủy",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "Lưu",
                is_enter_default = true,
                callback = function()
                    self.settings[key] = util.trim(dialog:getInputText() or "")
                    self:saveSettings()
                    UIManager:close(dialog)
                    if done then done() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ContextDict:editApiUrl(done)
    self:editText("Địa chỉ API", "api_url", "https://your-app.vercel.app/api/explain", done)
end

function ContextDict:editNumber(title, key, min, max, done)
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = self.settings[key],
        value_min = min,
        value_max = max,
        value_step = 5,
        default_value = DEFAULTS[key],
        callback = function(spin)
            self.settings[key] = spin.value
            self:saveSettings()
            if done then done() end
        end,
    })
end

function ContextDict:testApi()
    if not str(self.settings.api_url) then
        self:showNoApiMessage()
        return
    end
    local ctx = {
        selected = "bank",
        before = "After the long walk, they sat down on the grassy ",
        after = " of the river and watched the boats drift by.",
    }
    ctx.sentence = extractSentence(ctx.before, ctx.selected, ctx.after)
    local run = function()
        local info = InfoMessage:new{ text = "Đang thử kết nối API…", dismissable = false }
        UIManager:show(info)
        UIManager:forceRePaint()
        local ok, res = self:callApi(self:buildPayload("bank", ctx))
        UIManager:close(info)
        if not ok then
            UIManager:show(InfoMessage:new{ text = "Kết nối thất bại.\n\n" .. res })
            return
        end
        local html = self:renderHtml("bank", ctx, res)
        UIManager:show(TextViewer:new{
            title = "Kết nối API thành công",
            text = "Câu thử: " .. ctx.sentence .. "\n\n" ..
                html:gsub("<[^>]+>", "\n"):gsub("\n%s*\n+", "\n"),
        })
    end
    if NetworkMgr:willRerunWhenOnline(run) then return end
    run()
end

function ContextDict:addToMainMenu(menu_items)
    menu_items.contextdict = {
        text = "AI search",
        sorting_hint = "search",
        sub_item_table = {
            {
                text = "Tự động tra AI khi tra từ (hiện đầu tiên)",
                checked_func = function() return self.settings.auto_lookup end,
                callback = function()
                    self.settings.auto_lookup = not self.settings.auto_lookup
                    self:saveSettings()
                end,
            },
            {
                text_func = function()
                    local url = str(self.settings.api_url)
                    return "Địa chỉ API: " .. (url or "(chưa đặt)")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editApiUrl(function() touchmenu_instance:updateItems() end)
                end,
            },
            {
                text_func = function()
                    return "API key: " .. (str(self.settings.api_key) and "đã đặt" or "(không dùng)")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText("API key (gửi qua header Authorization: Bearer)", "api_key",
                        "để trống nếu API không cần", function() touchmenu_instance:updateItems() end)
                end,
            },
            {
                text_func = function()
                    return "Số từ ngữ cảnh mỗi bên: " .. self.settings.context_words
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editNumber("Số từ lấy trước/sau từ được chọn", "context_words", 5, 150,
                        function() touchmenu_instance:updateItems() end)
                end,
            },
            {
                text_func = function()
                    return "Thời gian chờ tối đa: " .. self.settings.timeout .. " giây"
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editNumber("Thời gian chờ API (giây)", "timeout", 5, 120,
                        function() touchmenu_instance:updateItems() end)
                end,
            },
            {
                text = "Thử kết nối API",
                separator = true,
                callback = function()
                    self:testApi()
                end,
            },
        },
    }
end

return ContextDict
