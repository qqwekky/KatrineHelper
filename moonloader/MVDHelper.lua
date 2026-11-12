script_name('MVD Helper')
script_author('qqwekky')
script_description('Хелпер для МВД Advance RP Blue с ИИ-напарником')
script_version('0.1.4')
script_properties('work-in-pause')

-- Файл в кодировке UTF-8. В чат всё уходит через u8:decode (CP1251).

require 'lib.moonloader'
local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- Перекодировки, которые не роняют скрипт на непереводимых символах
local function to1251(s)
    s = tostring(s or '')
    local ok, r = pcall(function() return u8:decode(s) end)
    if ok and type(r) == 'string' then return r end
    local plain = s:gsub('[\226-\244][\128-\191]*', '')
    ok, r = pcall(function() return u8:decode(plain) end)
    if ok and type(r) == 'string' then return r end
    return (s:gsub('[\128-\255]+', '?'))
end

local function toUtf(s)
    if type(s) ~= 'string' then return '' end
    local ok, r = pcall(function() return u8(s) end)
    if ok and type(r) == 'string' then return r end
    return (s:gsub('[\128-\255]', '?'))
end
local sampev = require 'lib.samp.events'
local vk = require 'vkeys'
local dlstatus = require('moonloader').download_status

-- Встроенный JSON (чтобы скрипт не зависел от dkjson)
local dkjson = (function()
    local escmap = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    local unesc = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

    local function escstr(s)
        local r = s:gsub('[%c"\\]', function(c) return escmap[c] or string.format('\\u%04x', c:byte()) end)
        return '"' .. r .. '"'
    end

    local function isArray(t)
        local n = 0
        for k in pairs(t) do
            if type(k) ~= 'number' then return false end
            n = n + 1
        end
        return n == #t
    end

    local function enc(v, indent, level)
        local tv = type(v)
        if tv == 'string' then return escstr(v) end
        if tv == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then return 'null' end
            return string.format('%.14g', v)
        end
        if tv == 'boolean' then return tostring(v) end
        if tv ~= 'table' then return 'null' end
        local nl, pad, pad0, colon = '', '', '', ':'
        if indent then
            nl = '\n'; pad = string.rep('  ', level + 1); pad0 = string.rep('  ', level); colon = ': '
        end
        local parts = {}
        if isArray(v) then
            if #v == 0 then return '[]' end
            for i = 1, #v do parts[i] = pad .. enc(v[i], indent, level + 1) end
            return '[' .. nl .. table.concat(parts, ',' .. nl) .. nl .. pad0 .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for i, k in ipairs(keys) do
            parts[i] = pad .. escstr(tostring(k)) .. colon .. enc(v[k], indent, level + 1)
        end
        return '{' .. nl .. table.concat(parts, ',' .. nl) .. nl .. pad0 .. '}'
    end

    local function utf8char(cp)
        local char, floor = string.char, math.floor
        if cp < 0x80 then return char(cp) end
        if cp < 0x800 then return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40) end
        if cp < 0x10000 then return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40) end
        return char(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40, 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end

    local function decodeRaw(str)
        local pos = 1
        local parseValue

        local function ws()
            pos = str:find('%S', pos) or (#str + 1)
        end

        local function parseString()
            pos = pos + 1
            local parts, n = {}, 0
            while true do
                local i = str:find('["\\]', pos)
                if not i then error('unterminated string') end
                n = n + 1; parts[n] = str:sub(pos, i - 1)
                if str:byte(i) == 34 then pos = i + 1 break end
                local c = str:sub(i + 1, i + 1)
                if c == 'u' then
                    local cp = tonumber(str:sub(i + 2, i + 5), 16) or 63
                    pos = i + 6
                    if cp >= 0xD800 and cp <= 0xDBFF and str:sub(pos, pos + 1) == '\\u' then
                        local lo = tonumber(str:sub(pos + 2, pos + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            pos = pos + 6
                        end
                    end
                    n = n + 1; parts[n] = utf8char(cp)
                else
                    n = n + 1; parts[n] = unesc[c] or c
                    pos = i + 2
                end
            end
            return table.concat(parts)
        end

        parseValue = function()
            ws()
            local c = str:byte(pos)
            if c == 123 then -- {
                local t = {}
                pos = pos + 1; ws()
                if str:byte(pos) == 125 then pos = pos + 1 return t end
                while true do
                    ws()
                    if str:byte(pos) ~= 34 then error('key expected at ' .. pos) end
                    local k = parseString()
                    ws()
                    if str:byte(pos) ~= 58 then error('colon expected at ' .. pos) end
                    pos = pos + 1
                    t[k] = parseValue()
                    ws()
                    local d = str:byte(pos); pos = pos + 1
                    if d == 125 then return t end
                    if d ~= 44 then error('comma expected at ' .. pos) end
                end
            elseif c == 91 then -- [
                local t, n = {}, 0
                pos = pos + 1; ws()
                if str:byte(pos) == 93 then pos = pos + 1 return t end
                while true do
                    n = n + 1; t[n] = parseValue()
                    ws()
                    local d = str:byte(pos); pos = pos + 1
                    if d == 93 then return t end
                    if d ~= 44 then error('comma expected at ' .. pos) end
                end
            elseif c == 34 then
                return parseString()
            elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
            elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
            elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
            else
                local s, e = str:find('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
                if not s then error('unexpected symbol at ' .. pos) end
                pos = e + 1
                return tonumber(str:sub(s, e))
            end
        end

        return parseValue()
    end

    return {
        encode = function(t, opt) return enc(t, opt and opt.indent, 0) end,
        decode = function(s)
            if type(s) ~= 'string' then return nil end
            local ok, r = pcall(decodeRaw, s)
            if ok then return r end
            return nil
        end,
    }
end)()
local effil_ok, effil = pcall(require, 'effil')

local VERSION = '0.1.4'
local clock = localClock or os.clock
local REPO_RAW = 'https://raw.githubusercontent.com/qqwekky/MVDHelper/main/'
local DIR = getWorkingDirectory() .. '/MVDHelper'
local CFG_PATH = getWorkingDirectory() .. '/config/MVDHelper.json'
local LAWS_PATH = DIR .. '/laws.json'
local PROV_PATH = DIR .. '/providers.json'

-------------------------------------------------------------------------------
-- Утилиты
-------------------------------------------------------------------------------
local function jdecode(s)
    return dkjson.decode(s)
end

local function jencode(t, pretty)
    if pretty then return dkjson.encode(t, { indent = true }) end
    return dkjson.encode(t)
end

local function readFile(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function writeFile(p, s)
    local f = io.open(p, 'wb')
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local TRACE_PATH = DIR .. '/trace.txt'
local traceState = { net = '-', ui = '-', bg = '-' }
local function trace(slot, stage)
    if traceState[slot] == stage then return end
    traceState[slot] = stage
    local f = io.open(TRACE_PATH, 'w')
    if f then
        f:write(os.date('%H:%M:%S'), ' net=', traceState.net, ' ui=', traceState.ui, ' bg=', traceState.bg)
        f:close()
    end
end

local function msg(text)
    sampAddChatMessage(to1251('{4A86E8}[MVD Helper] {FFFFFF}' .. text), -1)
end

local function say(text)
    sampSendChat(to1251(text))
end

local function stripColors(s)
    return (s:gsub('{%x%x%x%x%x%x}', ''))
end

local function rpName(nick)
    return (nick or ''):gsub('_', ' ')
end

local function deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == 'table' and type(dst[k]) == 'table' and #v == 0 then
            deepMerge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function versionNewer(a, b) -- a > b ?
    local function parts(v)
        local t = {}
        for n in tostring(v):gmatch('%d+') do t[#t + 1] = tonumber(n) end
        return t
    end
    local x, y = parts(a), parts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-------------------------------------------------------------------------------
-- Конфиг
-------------------------------------------------------------------------------
local DEPTS = { 'ЛСПД', 'СФПД', 'ЛВПД', 'ФБР' }
local DEPT_FULL = {
    ['ЛСПД'] = 'Полиция Лос-Сантоса',
    ['СФПД'] = 'Полиция Сан-Фиерро',
    ['ЛВПД'] = 'Полиция Лас-Вентураса',
    ['ФБР'] = 'Федеральное бюро расследований',
}

local DEFAULT_RP = {
    cuff     = { title = 'Надеть наручники', usage = '/cuff [id]', needId = true, lines = { '/me снял{a} наручники с пояса', '/me резким движением надел{a} наручники на {target}' } },
    uncuff   = { title = 'Снять наручники', usage = '/uncuff [id]', needId = true, lines = { '/me достал{a} ключ от наручников', '/me снял{a} наручники с {target} и убрал{a} их на пояс' } },
    hold     = { title = 'Вести за собой', usage = '/hold [id]', needId = true, lines = { '/me крепко взял{a} {target} за руку и повёл{a} за собой' } },
    eject    = { title = 'Выкинуть из авто', usage = '/eject [id]', needId = true, lines = { '/me открыл{a} дверь автомобиля и вывел{a} {target} наружу' } },
    putpl    = { title = 'Посадить в авто', usage = '/putpl [id]', needId = true, lines = { '/me открыл{a} заднюю дверь автомобиля', '/me усадил{a} {target} на заднее сиденье и закрыл{a} дверь' } },
    pull     = { title = 'Вытащить из авто', usage = '/pull [id]', needId = true, lines = { '/me разбил{a} стекло дубинкой и открыл{a} дверь изнутри', '/me вытащил{a} {target} из автомобиля' } },
    search   = { title = 'Обыск', usage = '/search [id]', needId = true, lines = { '/me надел{a} резиновые перчатки', '/me тщательно обыскал{a} {target}', '/do Результаты обыска зафиксированы в КПК.' } },
    arrest   = { title = 'Арест', usage = '/arrest [id]', needId = true, lines = { '/me заполнил{a} протокол задержания на {target}', '/do Протокол передан дежурному участка.' } },
    ticket   = { title = 'Штраф', usage = '/ticket [id] [сумма] [причина]', needId = true, lines = { '/me достал{a} блокнот и авторучку', '/me заполнил{a} бланк штрафа и протянул{a} его {target}' } },
    takelic  = { title = 'Изъять права', usage = '/takelic [id] [причина]', needId = true, lines = { '/me попросил{a} водительское удостоверение', '/me изъял{a} удостоверение у {target} и убрал{a} в карман' } },
    su       = { title = 'Выдать розыск', usage = '/su [id] [уровень] [причина]', needId = true, lines = { '/me достал{a} КПК и открыл{a} базу данных', '/me [внёс|внесла] {target} в федеральный розыск' } },
    clear    = { title = 'Снять розыск', usage = '/clear [id]', needId = true, lines = { '/me открыл{a} базу данных в КПК', '/me снял{a} {target} с розыска' } },
    mask     = { title = 'Маска', usage = '/mask', needId = false, lines = { '/me достал{a} маску из кармана и натянул{a} её на лицо' } },
    healme   = { title = 'Аптечка', usage = '/healme', needId = false, lines = { '/me достал{a} аптечку и обработал{a} рану' } },
    invite   = { title = 'Принять в отдел', usage = '/invite [id]', needId = true, lines = { '/me передал{a} форму и рацию {target}' } },
    uninvite = { title = 'Уволить', usage = '/uninvite [id] [причина]', needId = true, lines = { '/me забрал{a} у {target} форму и удостоверение' } },
    rang     = { title = 'Изменить звание', usage = '/rang [id] [+/-]', needId = true, lines = { '/me выдал{a} {target} новые погоны' } },
}
local RP_ORDER = { 'cuff', 'uncuff', 'hold', 'eject', 'putpl', 'pull', 'search', 'arrest', 'ticket', 'takelic', 'su', 'clear', 'mask', 'healme', 'invite', 'uninvite', 'rang' }

local DEFAULT_CFG = {
    profile = { name = '', rank = 'Сержант', dept = 'ЛСПД', female = false },
    delay = 1300,
    rp = {},
    megaphone = {
        'Водитель, прижмитесь к обочине и заглушите двигатель!',
        'Немедленно остановите транспортное средство!',
        'Выйдите из машины с поднятыми руками!',
        'Работает полиция! Всем оставаться на местах!',
        'Освободите дорогу служебному автомобилю!',
    },
    qsm = {
        '/r [QSM] Требуется подкрепление! Район: {zone}. Код 3.',
    },
    binds = {
        { cmd = 'privet', lines = { 'Здравствуйте, я {rank} {dept}, {name}.', '/me показал{a} удостоверение' } },
    },
    filter = { enabled = false, words = { 'Объявление:', 'Отредактировал сотрудник' } },
    ai = {
        enabled = true,
        interval = 6,
        key = 'F3',
        custom_url = '',
        custom_key = '',
        custom_model = '',
        keywords = { 'розыск', 'наручник', 'задерж', 'арест', 'выстрел', 'стреля', 'ранил', 'убил', 'ограб', 'похищ', 'погон', 'угон', 'штраф', 'обыск', 'документ', 'паспорт', 'права', 'удостоверени', 'адвокат', 'оружи', 'наркот', 'маск' },
    },
    autologin = { enabled = false, password = '' },
    autoupdate = true,
    partner = { x = 20, y = 300, w = 340, h = 330 },
}

local cfg

local function saveCfg()
    writeFile(CFG_PATH, jencode(cfg, true))
end

local function loadCfg()
    local s = readFile(CFG_PATH)
    cfg = (s and jdecode(s)) or {}
    deepMerge(cfg, DEFAULT_CFG)
    for k, v in pairs(DEFAULT_RP) do
        if not cfg.rp[k] then
            cfg.rp[k] = { enabled = true, lines = v.lines }
        end
    end
    saveCfg()
end

-------------------------------------------------------------------------------
-- Шаблоны отыгровок
-------------------------------------------------------------------------------
local function myId()
    local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    return id
end

local function fill(line, ctx)
    local p = cfg.profile
    local female = p.female
    line = line:gsub('{a}', female and 'а' or '')
    line = line:gsub('%[([^|%]]*)|([^%]]*)%]', function(m, f) return female and f or m end)
    local name = p.name ~= '' and p.name or rpName(sampGetPlayerNickname(myId()))
    local rep = {
        name = name, rank = p.rank, dept = p.dept, deptfull = DEPT_FULL[p.dept] or p.dept,
        target = ctx and ctx.target or 'человека', arg = ctx and ctx.arg or '', zone = ctx and ctx.zone or '',
    }
    line = line:gsub('{(%w+)}', function(k) return rep[k] or ('{' .. k .. '}') end)
    return line
end

local busy = false
local function playLines(lines, ctx, final)
    if busy then msg('Подождите, идёт отыгровка.') return end
    busy = true
    lua_thread.create(function()
        for i, l in ipairs(lines) do
            say(fill(l, ctx))
            if i < #lines or final then wait(cfg.delay) end
        end
        if final then sampSendChat(final) end
        busy = false
    end)
end

local function parseIdArgs(raw)
    local id, rest = raw:match('^%s*(%d+)%s*(.-)%s*$')
    return tonumber(id), rest or ''
end

local function makeRpHandler(key, withRp)
    local def = DEFAULT_RP[key]
    return function(raw)
        raw = raw or ''
        local ctx = { arg = toUtf(raw) }
        if def.needId then
            local id, rest = parseIdArgs(raw)
            if not id or not sampIsPlayerConnected(id) then
                msg('Используйте: ' .. def.usage)
                return
            end
            ctx.target = rpName(sampGetPlayerNickname(id))
            ctx.arg = toUtf(rest)
        end
        local final = '/' .. key .. (raw ~= '' and (' ' .. raw) or '')
        local rc = cfg.rp[key]
        if withRp and rc and rc.enabled then
            playLines(rc.lines, ctx, final)
        else
            sampSendChat(final)
        end
    end
end

-------------------------------------------------------------------------------
-- База законов и поиск
-------------------------------------------------------------------------------
local laws = { docs = {}, version = '—', changes = {}, flat = {}, df = {}, loaded = false }

local LOWER = {}
do
    local up = 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'
    local lo = 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя'
    local U, L = {}, {}
    for ch in up:gmatch('[\208\209][\128-\191]') do U[#U + 1] = ch end
    for ch in lo:gmatch('[\208\209][\128-\191]') do L[#L + 1] = ch end
    for i = 1, #U do LOWER[U[i]] = L[i] end
end

local function ulower(s)
    s = s:gsub('[\208\209][\128-\191]', function(c) return LOWER[c] or c end)
    return s:lower()
end

local STOP = { ['или'] = true, ['для'] = true, ['что'] = true, ['это'] = true, ['как'] = true, ['так'] = true, ['его'] = true, ['она'] = true, ['они'] = true, ['при'] = true, ['без'] = true, ['под'] = true, ['над'] = true, ['все'] = true, ['был'] = true, ['так'] = true }

local function stems(text)
    local out = {}
    text = ulower(text):gsub('ё', 'е')
    for w in text:gmatch('[%a\208\209\128-\191]+') do
        local chars = {}
        for ch in w:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = ch end
        if #chars >= 3 and not STOP[w] then
            out[#out + 1] = table.concat(chars, '', 1, math.min(#chars, 5))
        end
    end
    return out
end

local GLYPH_OK = {}
for ch in ('‚„…†‡€‰‹‘’“”•–—™›№«»→'):gmatch('[\194-\244][\128-\191]*') do GLYPH_OK[ch] = true end
local GLYPH_MAP = {
    ['−'] = '-', ['‐'] = '-', ['‑'] = '-', ['―'] = '—', ['⅔'] = '2/3', ['½'] = '1/2', ['¼'] = '1/4',
    ['✓'] = '+', ['✔'] = '+', ['✅'] = '+', ['❌'] = 'x', ['✗'] = 'x', ['✘'] = 'x',
    ['●'] = '•', ['▪'] = '•', ['■'] = '•', ['◦'] = '•', ['◆'] = '•', ['·'] = '•',
    ['▸'] = '→', ['►'] = '→', ['➡'] = '→', ['⇒'] = '→', ['➜'] = '→', ['➤'] = '→',
    ['\194\160'] = ' ', ['\226\128\175'] = ' ', ['\226\128\137'] = ' ',
}
local function clean(s)
    if type(s) ~= 'string' then return '' end
    if not s:find('[\194-\244]') then return s end
    return (s:gsub('[\194-\244][\128-\191]*', function(ch)
        if GLYPH_MAP[ch] then return GLYPH_MAP[ch] end
        local b = ch:byte()
        if (b >= 208 and b <= 211) or b == 194 or b == 195 then return ch end
        if GLYPH_OK[ch] then return ch end
        return ''
    end))
end

local function indexLaws()
    laws.flat, laws.df = {}, {}
    for _, d in ipairs(laws.docs) do
        for _, a in ipairs(d.articles or {}) do
            local set = {}
            for _, s in ipairs(stems((a.ch or '') .. ' ' .. (a.t or ''))) do set[s] = true end
            for s in pairs(set) do laws.df[s] = (laws.df[s] or 0) + 1 end
            laws.flat[#laws.flat + 1] = { doc = d.id, n = tostring(a.n), ch = clean(a.ch or ''), t = clean(a.t or ''), w = tonumber(a.w), f = tonumber(a.f), set = set }
        end
    end
end

local function loadLaws()
    local s = readFile(LAWS_PATH)
    if not s then return false end
    local data = jdecode(s)
    if not data or not data.docs then return false end
    laws.docs = data.docs
    laws.version = data.version or '—'
    laws.changes = data.changes or {}
    indexLaws()
    laws.loaded = true
    return true
end

local CRIMINAL = { ['УК'] = true, ['АК'] = true }

local function searchLaws(query, limit, groupSplit)
    local q = {}
    for _, s in ipairs(stems(query)) do q[s] = true end
    local N = #laws.flat
    local scored = {}
    for _, a in ipairs(laws.flat) do
        local sc = 0
        for s in pairs(q) do
            if a.set[s] then sc = sc + math.log((N + 1) / (laws.df[s] or 1)) end
        end
        if sc > 0 then scored[#scored + 1] = { a = a, s = sc } end
    end
    table.sort(scored, function(x, y) return x.s > y.s end)
    local res = {}
    if groupSplit then
        local c1, c2 = 0, 0
        local half = math.floor(limit / 2)
        for _, it in ipairs(scored) do
            if CRIMINAL[it.a.doc] and c1 < half then c1 = c1 + 1; res[#res + 1] = it.a
            elseif not CRIMINAL[it.a.doc] and c2 < limit - half then c2 = c2 + 1; res[#res + 1] = it.a end
            if c1 + c2 >= limit then break end
        end
    else
        for i = 1, math.min(limit, #scored) do res[#res + 1] = scored[i].a end
    end
    return res
end

local function wantedArticles(filter)
    local res = {}
    local f = filter and filter ~= '' and ulower(filter) or nil
    for _, a in ipairs(laws.flat) do
        if a.doc == 'УК' and a.w then
            if not f or ulower(a.n .. ' ' .. a.t):find(f, 1, true) then res[#res + 1] = a end
        end
    end
    return res
end

-------------------------------------------------------------------------------
-- Загрузки с GitHub
-------------------------------------------------------------------------------
local function download(url, path, cb)
    downloadUrlToFile(url, path, function(_, status)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            if cb then cb(true) end
        end
    end)
end

local function checkLaws()
    local tmp = DIR .. '/laws_version.tmp'
    download(REPO_RAW .. 'data/laws_version.json', tmp, function()
        lua_thread.create(function()
            wait(300)
            local remote = jdecode(readFile(tmp) or '') or {}
            os.remove(tmp)
            if not remote.version then
                if not laws.loaded then msg('Не удалось получить базу законов. Проверьте интернет.') end
                return
            end
            if not laws.loaded or remote.version ~= laws.version then
                msg('Загружаю базу законов от ' .. remote.version .. '...')
                download(REPO_RAW .. 'data/laws.json', LAWS_PATH, function()
                    lua_thread.create(function()
                        wait(500)
                        if loadLaws() then
                            msg('База законов обновлена: ' .. #laws.flat .. ' статей.')
                            for _, c in ipairs(laws.changes) do msg('{AAAAAA}' .. c) end
                        end
                    end)
                end)
            end
        end)
    end)
end

local providers = {
    { name = 'LLM7', type = 'openai', url = 'https://api.llm7.io/v1/chat/completions', key = 'unused', model = 'default' },
    { name = 'Pollinations', type = 'pollinations', url = 'https://text.pollinations.ai/', model = 'openai' },
}

local function loadProviders()
    local s = readFile(PROV_PATH)
    local p = s and jdecode(s)
    if p and p.providers and #p.providers > 0 then providers = p.providers end
end

local function checkProviders()
    download(REPO_RAW .. 'data/providers.json', PROV_PATH, function()
        lua_thread.create(function() wait(300) loadProviders() end)
    end)
end

local function checkUpdate()
    local tmp = DIR .. '/version.tmp'
    download(REPO_RAW .. 'version.json', tmp, function()
        lua_thread.create(function()
            wait(300)
            local v = jdecode(readFile(tmp) or '') or {}
            os.remove(tmp)
            if v.version and versionNewer(v.version, VERSION) then
                msg('Найдена новая версия ' .. v.version .. '. Обновляюсь...')
                download(REPO_RAW .. 'moonloader/MVDHelper.lua', thisScript().path, function()
                    lua_thread.create(function()
                        wait(500)
                        msg('Обновлено. Перезапуск скрипта.')
                        thisScript():reload()
                    end)
                end)
            end
        end)
    end)
end

-------------------------------------------------------------------------------
-- HTTP без подвисаний игры: effil (если есть) или неблокирующие сокеты
-------------------------------------------------------------------------------
local function log(text)
    print(to1251('[MVD Helper] ' .. tostring(text)))
end

local function dechunk(body)
    local out, pos = {}, 1
    while true do
        local s, e, hex = body:find('^(%x+)[^\r\n]*\r\n', pos)
        if not s then break end
        local size = tonumber(hex, 16)
        if not size or size == 0 then break end
        out[#out + 1] = body:sub(e + 1, e + size)
        pos = e + size + 3
    end
    return table.concat(out)
end

local function socketHttp(method, url, args)
    local socket = require 'socket'
    local ssl = require 'ssl'
    local host, path = url:match('^https://([^/]+)(.*)$')
    if not host then error('нужен https адрес') end
    if path == '' then path = '/' end
    local port = 443
    local h, p = host:match('^(.+):(%d+)$')
    if h then host, port = h, tonumber(p) end
    local deadline = clock() + (args.timeout or 25)
    local function check()
        if clock() > deadline then error('таймаут') end
        wait(0)
    end

    trace('net', 'dns ' .. host)
    local ip = socket.dns.toip(host)
    if not ip then error('не найден адрес ' .. host) end
    local tcp = socket.tcp()
    local conn
    local ok, err = pcall(function()
        trace('net', 'connect')
        tcp:settimeout(0)
        tcp:connect(ip, port)
        while true do
            local _, w = socket.select(nil, { tcp }, 0)
            if w and #w > 0 then break end
            check()
        end

        trace('net', 'tls')
        local ctx, cerr
        for _, proto in ipairs({ 'any', 'tlsv1_2', 'sslv23', 'tlsv1' }) do
            local okc, c = pcall(ssl.newcontext, { mode = 'client', protocol = proto, verify = 'none', options = 'all' })
            if okc and c then ctx = c break end
            cerr = c
        end
        if not ctx then error('ssl: ' .. tostring(cerr)) end
        local werr
        conn, werr = ssl.wrap(tcp, ctx)
        if not conn then error('ssl.wrap: ' .. tostring(werr)) end
        if conn.sni then conn:sni(host) end
        conn:settimeout(0)
        while true do
            local hs, herr = conn:dohandshake()
            if hs then break end
            if herr ~= 'wantread' and herr ~= 'wantwrite' and herr ~= 'timeout' then error('handshake: ' .. tostring(herr)) end
            check()
        end

        trace('net', 'send')
        local body = args.data or ''
        local lines = {
            method .. ' ' .. path .. ' HTTP/1.1',
            'Host: ' .. host,
            'User-Agent: MVDHelper/' .. VERSION,
            'Accept: */*',
            'Accept-Encoding: identity',
            'Connection: close',
            'Content-Length: ' .. #body,
        }
        for k, v in pairs(args.headers or {}) do lines[#lines + 1] = k .. ': ' .. v end
        local req = table.concat(lines, '\r\n') .. '\r\n\r\n' .. body
        local i = 1
        while i <= #req do
            local sent, serr, last = conn:send(req, i)
            if sent then
                i = sent + 1
            elseif serr == 'wantwrite' or serr == 'wantread' or serr == 'timeout' then
                if last and last >= i then i = last + 1 end
                check()
            else
                error('send: ' .. tostring(serr))
            end
        end

        trace('net', 'recv')
        local chunks = {}
        local total, headEnd, need, chunked = '', nil, nil, false
        while true do
            local data, rerr, partial = conn:receive(8192)
            local got = data or partial
            if got and #got > 0 then
                chunks[#chunks + 1] = got
                total = table.concat(chunks)
                chunks = { total }
                if not headEnd then
                    local _, e = total:find('\r\n\r\n', 1, true)
                    if e then
                        headEnd = e
                        local head = total:sub(1, e):lower()
                        need = tonumber(head:match('content%-length:%s*(%d+)'))
                        chunked = head:find('transfer%-encoding:%s*chunked') ~= nil
                    end
                end
                if headEnd then
                    if need and #total - headEnd >= need then break end
                    if chunked and total:sub(-5) == '0\r\n\r\n' then break end
                end
            end
            if not data then
                if rerr == 'closed' then break end
                if rerr ~= 'wantread' and rerr ~= 'wantwrite' and rerr ~= 'timeout' then
                    if headEnd then break end
                    error('receive: ' .. tostring(rerr))
                end
                check()
            end
        end
        if not headEnd then error('пустой ответ') end
        local status = tonumber(total:match('^HTTP/%d%.%d%s+(%d+)')) or 0
        local text = total:sub(headEnd + 1)
        if chunked then text = dechunk(text) end
        return { status_code = status, text = text }
    end)
    trace('net', 'close')
    pcall(function() if conn then conn:close() else tcp:close() end end)
    trace('net', '-')
    if not ok then error(err, 0) end
    return err
end

local function asyncHttp(method, url, args, resolve, reject)
    if effil_ok then
        local thread = effil.thread(function(m, u, a)
            local requests = require 'requests'
            local ok, resp = pcall(requests.request, m, u, a)
            if ok then
                return true, { status_code = resp.status_code, text = resp.text }
            end
            return false, tostring(resp)
        end)(method, url, args)
        lua_thread.create(function()
            while true do
                local status, err = thread:status()
                if err then return reject(tostring(err)) end
                if status == 'completed' then
                    local ok, resp = thread:get()
                    if ok then return resolve(resp) end
                    return reject(tostring(resp))
                elseif status == 'canceled' then
                    return reject('canceled')
                end
                wait(0)
            end
        end)
        return
    end
    lua_thread.create(function()
        local ok, resp = pcall(socketHttp, method, url, args)
        if ok then return resolve(resp) end
        reject(tostring(resp))
    end)
end

-------------------------------------------------------------------------------
-- ИИ-напарник
-------------------------------------------------------------------------------
local ai = {
    buffer = {},          -- { t = clock(), s = 'текст' }
    dirty = false,
    lastEvent = 0,
    lastCall = -100,
    pending = false,
    status = 'ожидание',
    provider = '',
    result = nil,         -- таблица ответа
    raw = '',
    refs = {},            -- найденные статьи
    nearby = {},
    question = nil,
}

local HINTS = {
    ['/cuff'] = 'наручники задержание', ['/search'] = 'обыск досмотр', ['/arrest'] = 'арест задержание',
    ['/ticket'] = 'штраф административное', ['/takelic'] = 'лишение водительского удостоверения',
    ['/su'] = 'розыск', ['/putpl'] = 'задержанный транспортировка', ['/pull'] = 'неподчинение транспорт',
    ['фар'] = 'остановка транспортного средства водитель документы', ['останов'] = 'остановка транспортного средства',
    ['документ'] = 'предъявление документов удостоверение личности', ['адвокат'] = 'адвокат право задержанного',
    ['уехал'] = 'неподчинение уклонение', ['поехал'] = 'неподчинение уклонение', ['убежал'] = 'уклонение от задержания',
    ['маск'] = 'маска сокрытие лица',
}

local function pushEvent(s, force)
    if not cfg.ai.enabled then return end
    s = stripColors(s)
    if s == '' then return end
    local relevant = force
    if not relevant then
        local low = ulower(s)
        for nick in pairs(ai.nearby) do
            if s:find(nick, 1, true) or s:find(rpName(nick), 1, true) then relevant = true break end
        end
        if not relevant then
            for _, k in ipairs(cfg.ai.keywords) do
                if low:find(k, 1, true) then relevant = true break end
            end
        end
    end
    if not relevant then return end
    table.insert(ai.buffer, { t = clock(), s = s })
    while #ai.buffer > 25 do table.remove(ai.buffer, 1) end
    ai.dirty = true
    ai.lastEvent = clock()
end

local function updateNearby()
    local res = {}
    local mx, my, mz = getCharCoordinates(PLAYER_PED)
    for _, ped in ipairs(getAllChars and getAllChars() or {}) do
        if ped ~= PLAYER_PED and doesCharExist(ped) then
            local ok, id = sampGetPlayerIdByCharHandle(ped)
            if ok and id and id >= 0 then
                local x, y, z = getCharCoordinates(ped)
                if getDistanceBetweenCoords3d(mx, my, mz, x, y, z) < 40 then
                    local nick = sampGetPlayerNickname(id)
                    if nick then res[nick] = true end
                end
            end
        end
    end
    local me = sampGetPlayerNickname(myId())
    if me then res[me] = true end
    ai.nearby = res
end

local SYSTEM_PROMPT = [[Ты опытный напарник сотрудника МВД на RolePlay сервере Advance RP (Blue). Ты читаешь игровой чат вокруг игрока и подсказываешь, как правильно действовать по закону.
Правила:
1. Опирайся ТОЛЬКО на статьи из блока СТАТЬИ. Не выдумывай номера статей. Если подходящей статьи нет, так и скажи.
2. Учитывай процедуру (ПК, Устав, правила МВД): представиться, назвать причину, предъявить удостоверение, зачитать права и т.д.
3. Пиши кратко, по-русски, без воды.
4. Ответ строго JSON без пояснений вокруг:
{"situation":"кратко что происходит","checklist":[{"step":"шаг процедуры","done":true}],"next":"что сделать сейчас","warning":"ошибка или риск нарушения, либо пусто","refs":[{"doc":"УК","n":"1.1","why":"почему подходит"}],"command":"готовая команда, например /su 12 3 УК 1.1, либо пусто"}]]

local function buildPrompt(question)
    local lines = {}
    for i = math.max(1, #ai.buffer - 14), #ai.buffer do lines[#lines + 1] = ai.buffer[i].s end
    local chatText = table.concat(lines, '\n')
    local q = chatText
    for k, v in pairs(HINTS) do
        if ulower(chatText):find(k, 1, true) then q = q .. ' ' .. v end
    end
    if question then q = q .. ' ' .. question end
    ai.refs = laws.loaded and searchLaws(q, 8, true) or {}
    local arts = {}
    for _, a in ipairs(ai.refs) do
        local t = a.t
        if #t > 700 then t = t:sub(1, 700):gsub('[\192-\255][\128-\191]*$', '') .. '…' end
        arts[#arts + 1] = string.format('[%s %s] %s', a.doc, a.n, t)
    end
    local p = cfg.profile
    local me = sampGetPlayerNickname(myId()) or ''
    local user = 'ИГРОК: ' .. me .. ' (' .. p.rank .. ', ' .. p.dept .. ')\n'
    if ai.result and ai.result.situation then
        user = user .. 'ПРЕДЫДУЩАЯ ОЦЕНКА: ' .. tostring(ai.result.situation) .. '\n'
    end
    user = user .. '\nЧАТ (последние события):\n' .. chatText .. '\n\nСТАТЬИ:\n' .. table.concat(arts, '\n')
    if question then user = user .. '\n\nВОПРОС ИГРОКА: ' .. question end
    return user
end

local function parseAnswer(text)
    local s = text:match('%b{}')
    local t = s and jdecode(s)
    if type(t) == 'table' then return t end
    return { situation = '', next = clean(text) }
end

local function callProvider(i, prompt, done)
    local list = {}
    if cfg.ai.custom_url ~= '' and cfg.ai.custom_key ~= '' then
        list[#list + 1] = { name = 'Свой ключ', type = 'openai', url = cfg.ai.custom_url, key = cfg.ai.custom_key, model = cfg.ai.custom_model }
    end
    for _, p in ipairs(providers) do list[#list + 1] = p end
    local p = list[i]
    if not p then return done(nil) end
    local messages = { { role = 'system', content = SYSTEM_PROMPT }, { role = 'user', content = prompt } }
    local body, headers
    if p.type == 'pollinations' then
        body = jencode({ messages = messages, model = p.model, jsonMode = true })
        headers = { ['Content-Type'] = 'application/json' }
    else
        body = jencode({ model = p.model, messages = messages, temperature = 0.2, max_tokens = 600 })
        headers = { ['Content-Type'] = 'application/json', ['Authorization'] = 'Bearer ' .. (p.key or '') }
    end
    ai.status = 'спрашиваю ' .. p.name .. '...'
    asyncHttp('POST', p.url, { headers = headers, data = body, timeout = 25 }, function(resp)
        if resp.status_code ~= 200 then
            log('ИИ ' .. p.name .. ': код ' .. tostring(resp.status_code) .. ' ' .. tostring(resp.text or ''):sub(1, 200))
            return callProvider(i + 1, prompt, done)
        end
        local text = resp.text or ''
        if p.type ~= 'pollinations' then
            local j = jdecode(text)
            text = j and j.choices and j.choices[1] and j.choices[1].message and j.choices[1].message.content
            if not text then
                log('ИИ ' .. p.name .. ': непонятный ответ')
                return callProvider(i + 1, prompt, done)
            end
        end
        ai.provider = p.name
        done(text)
    end, function(err)
        log('ИИ ' .. p.name .. ': ' .. tostring(err))
        callProvider(i + 1, prompt, done)
    end)
end

local function askAI(question)
    if ai.pending then return end
    ai.pending = true
    ai.dirty = false
    ai.lastCall = clock()
    trace('net', 'prompt')
    local prompt = buildPrompt(question)
    trace('net', '-')
    callProvider(1, prompt, function(text)
        ai.pending = false
        if not text then
            ai.status = 'ИИ недоступен, показываю статьи'
            ai.provider = ''
            ai.result = { situation = 'ИИ недоступен', next = 'Ниже похожие статьи из базы.' }
            return
        end
        trace('net', 'parse')
        ai.raw = text
        ai.result = parseAnswer(text)
        ai.status = 'готово'
        trace('net', '-')
    end)
end

-------------------------------------------------------------------------------
-- Интерфейс (mimgui)
-------------------------------------------------------------------------------
local new = imgui.new
local showMenu = new.bool(false)
local showPartner = new.bool(true)
local showSus = new.bool(false)
local showQuick = new.bool(false)
local susTarget = -1
local quickTarget = -1
local page = 1
local fontBold = nil
local dpi = 1
local function S(v) return math.floor(v * dpi + 0.5) end
local glyphRanges = nil

local CLR = {
    accent = imgui.ImVec4(0.36, 0.62, 1.00, 1),
    muted  = imgui.ImVec4(0.58, 0.62, 0.70, 1),
    text   = imgui.ImVec4(0.92, 0.93, 0.95, 1),
    good   = imgui.ImVec4(0.42, 0.85, 0.50, 1),
    bad    = imgui.ImVec4(0.96, 0.47, 0.42, 1),
    warn   = imgui.ImVec4(1.00, 0.70, 0.30, 1),
    btnOn  = imgui.ImVec4(0.20, 0.42, 0.85, 1),
    btnOff = imgui.ImVec4(0.14, 0.16, 0.21, 1),
}

-- Текст без printf-форматирования: безопасно для любых символов и длины
local function text(s)
    imgui.PushTextWrapPos(0)
    imgui.TextUnformatted(tostring(s))
    imgui.PopTextWrapPos()
end

local function colored(c, s)
    imgui.PushStyleColor(imgui.Col.Text, c)
    text(s)
    imgui.PopStyleColor(1)
end

local function muted(s) colored(CLR.muted, s) end

local function header(s)
    imgui.Spacing()
    if fontBold then imgui.PushFont(fontBold) end
    colored(CLR.accent, s)
    if fontBold then imgui.PopFont() end
    imgui.Separator()
    imgui.Spacing()
end

local function row(left, right)
    colored(CLR.accent, left)
    imgui.SameLine(S(200))
    text(right)
end

local function sval(v)
    if type(v) == 'string' then return clean(v) end
    if type(v) == 'number' then return tostring(v) end
    return ''
end

local function cut(s, n)
    if #s <= n then return s end
    s = s:sub(1, n)
    -- не оставляем оборванный UTF-8 символ в конце
    s = s:gsub('[\192-\255][\128-\191]*$', '')
    return s .. '…'
end

local function toggleButton(label, active, w, h)
    imgui.PushStyleColor(imgui.Col.Button, active and CLR.btnOn or CLR.btnOff)
    local clicked = imgui.Button(label, imgui.ImVec2(w or 0, h or 0))
    imgui.PopStyleColor(1)
    return clicked
end

local buf = {
    name = new.char[64](), rank = new.char[64](), lawq = new.char[128](), susq = new.char[128](),
    custom_url = new.char[256](), custom_key = new.char[256](), custom_model = new.char[128](),
    pass = new.char[64](), filter = new.char[1024](), mega = new.char[2048](), qsm = new.char[1024](),
    rp = {}, bindCmd = {}, bindLines = {}, delay = new.int(1300), interval = new.int(6),
    female = new.bool(false), aiOn = new.bool(true), alOn = new.bool(false), filterOn = new.bool(false), upd = new.bool(true),
    rpOn = {},
}

local function setBuf(b, s)
    s = tostring(s or ''):sub(1, ffi.sizeof(b) - 1)
    ffi.copy(b, s)
end
local function getBuf(b) return ffi.string(b) end
local function joinLines(t) return table.concat(t or {}, '\n') end
local function splitLines(s)
    local t = {}
    for l in (s .. '\n'):gmatch('(.-)\r?\n') do if l:match('%S') then t[#t + 1] = l end end
    return t
end

local function field(label, id, b, hint, flags)
    muted(label)
    imgui.SetNextItemWidth(-1)
    if hint then
        return imgui.InputTextWithHint('##' .. id, hint, b, ffi.sizeof(b), flags or 0)
    end
    return imgui.InputText('##' .. id, b, ffi.sizeof(b), flags or 0)
end

local function area(id, b, h)
    return imgui.InputTextMultiline('##' .. id, b, ffi.sizeof(b), imgui.ImVec2(-1, S(h)))
end

local function syncBuffers()
    local p = cfg.profile
    setBuf(buf.name, p.name); setBuf(buf.rank, p.rank)
    buf.female[0] = p.female; buf.delay[0] = cfg.delay; buf.interval[0] = cfg.ai.interval
    buf.aiOn[0] = cfg.ai.enabled; buf.alOn[0] = cfg.autologin.enabled; buf.filterOn[0] = cfg.filter.enabled
    buf.upd[0] = cfg.autoupdate
    setBuf(buf.custom_url, cfg.ai.custom_url); setBuf(buf.custom_key, cfg.ai.custom_key); setBuf(buf.custom_model, cfg.ai.custom_model)
    setBuf(buf.pass, cfg.autologin.password)
    setBuf(buf.filter, joinLines(cfg.filter.words)); setBuf(buf.mega, joinLines(cfg.megaphone)); setBuf(buf.qsm, joinLines(cfg.qsm))
    for _, k in ipairs(RP_ORDER) do
        buf.rp[k] = new.char[1024](); setBuf(buf.rp[k], joinLines(cfg.rp[k].lines))
        buf.rpOn[k] = new.bool(cfg.rp[k].enabled)
    end
    buf.bindCmd, buf.bindLines = {}, {}
    for i, b in ipairs(cfg.binds) do
        buf.bindCmd[i] = new.char[32](); setBuf(buf.bindCmd[i], b.cmd)
        buf.bindLines[i] = new.char[1024](); setBuf(buf.bindLines[i], joinLines(b.lines))
    end
end

local registerBinds

local function applyBuffers()
    local p = cfg.profile
    p.name = getBuf(buf.name); p.rank = getBuf(buf.rank); p.female = buf.female[0]
    cfg.delay = buf.delay[0]; cfg.ai.interval = math.max(3, buf.interval[0])
    cfg.ai.enabled = buf.aiOn[0]; cfg.autologin.enabled = buf.alOn[0]; cfg.filter.enabled = buf.filterOn[0]
    cfg.autoupdate = buf.upd[0]
    cfg.ai.custom_url = getBuf(buf.custom_url); cfg.ai.custom_key = getBuf(buf.custom_key); cfg.ai.custom_model = getBuf(buf.custom_model)
    cfg.autologin.password = getBuf(buf.pass)
    cfg.filter.words = splitLines(getBuf(buf.filter)); cfg.megaphone = splitLines(getBuf(buf.mega)); cfg.qsm = splitLines(getBuf(buf.qsm))
    for _, k in ipairs(RP_ORDER) do
        cfg.rp[k].lines = splitLines(getBuf(buf.rp[k])); cfg.rp[k].enabled = buf.rpOn[k][0]
    end
    for i, b in ipairs(cfg.binds) do
        b.cmd = getBuf(buf.bindCmd[i]):gsub('[^%w_]', ''); b.lines = splitLines(getBuf(buf.bindLines[i]))
    end
    saveCfg()
    registerBinds()
    msg('Настройки сохранены.')
end

local function applyStyle()
    imgui.SwitchContext()
    local s = imgui.GetStyle()
    local c = s.Colors
    local C = imgui.Col
    local V4 = imgui.ImVec4
    s.WindowRounding = 10; s.ChildRounding = 8; s.FrameRounding = 6; s.GrabRounding = 6
    s.PopupRounding = 8; s.ScrollbarRounding = 8; s.TabRounding = 6
    s.WindowBorderSize = 1; s.ChildBorderSize = 1; s.FrameBorderSize = 0
    s.WindowPadding = imgui.ImVec2(16, 14); s.FramePadding = imgui.ImVec2(10, 6)
    s.ItemSpacing = imgui.ImVec2(8, 8); s.ItemInnerSpacing = imgui.ImVec2(6, 5)
    s.ScrollbarSize = 12; s.GrabMinSize = 10
    s.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)

    c[C.Text]                 = V4(0.92, 0.93, 0.95, 1)
    c[C.TextDisabled]         = V4(0.50, 0.54, 0.62, 1)
    c[C.WindowBg]             = V4(0.07, 0.08, 0.11, 0.97)
    c[C.ChildBg]              = V4(0.10, 0.11, 0.15, 1)
    c[C.PopupBg]              = V4(0.09, 0.10, 0.14, 0.98)
    c[C.Border]               = V4(0.20, 0.23, 0.30, 1)
    c[C.FrameBg]              = V4(0.14, 0.16, 0.21, 1)
    c[C.FrameBgHovered]       = V4(0.18, 0.21, 0.28, 1)
    c[C.FrameBgActive]        = V4(0.20, 0.24, 0.32, 1)
    c[C.TitleBg]              = V4(0.09, 0.10, 0.14, 1)
    c[C.TitleBgActive]        = V4(0.11, 0.13, 0.19, 1)
    c[C.TitleBgCollapsed]     = V4(0.09, 0.10, 0.14, 1)
    c[C.ScrollbarBg]          = V4(0.08, 0.09, 0.12, 0.6)
    c[C.ScrollbarGrab]        = V4(0.24, 0.28, 0.36, 1)
    c[C.ScrollbarGrabHovered] = V4(0.30, 0.35, 0.45, 1)
    c[C.ScrollbarGrabActive]  = V4(0.36, 0.62, 1.00, 1)
    c[C.CheckMark]            = V4(0.36, 0.62, 1.00, 1)
    c[C.SliderGrab]           = V4(0.36, 0.62, 1.00, 1)
    c[C.SliderGrabActive]     = V4(0.50, 0.72, 1.00, 1)
    c[C.Button]               = V4(0.17, 0.33, 0.66, 1)
    c[C.ButtonHovered]        = V4(0.23, 0.44, 0.86, 1)
    c[C.ButtonActive]         = V4(0.15, 0.29, 0.58, 1)
    c[C.Header]               = V4(0.17, 0.33, 0.66, 0.55)
    c[C.HeaderHovered]        = V4(0.23, 0.44, 0.86, 0.65)
    c[C.HeaderActive]         = V4(0.23, 0.44, 0.86, 0.85)
    c[C.Separator]            = V4(0.20, 0.23, 0.30, 1)
    c[C.ResizeGrip]           = V4(0.36, 0.62, 1.00, 0.20)
    c[C.ResizeGripHovered]    = V4(0.36, 0.62, 1.00, 0.60)
    c[C.ResizeGripActive]     = V4(0.36, 0.62, 1.00, 0.90)
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    local okDpi, scale = pcall(imgui.GetDpiScale)
    if okDpi and type(scale) == 'number' and scale > 0.5 and scale < 4 then dpi = scale end
    -- в режиме 4 mimgui сам масштабирует шрифты, в остальных это делаем мы
    local okMode, mode = pcall(imgui.GetDpiScalingMode)
    local fs = (okMode and mode == 4) and 1 or dpi
    local fonts = getFolderPath(0x14) .. '\\'
    local regular = doesFileExist(fonts .. 'segoeui.ttf') and (fonts .. 'segoeui.ttf') or (fonts .. 'trebucbd.ttf')
    local bold = doesFileExist(fonts .. 'segoeuib.ttf') and (fonts .. 'segoeuib.ttf') or (fonts .. 'trebucbd.ttf')
    if doesFileExist(regular) then
        -- кириллица + типографские знаки, иначе вместо них рисуются вопросительные знаки
        local builder = imgui.ImFontGlyphRangesBuilder()
        builder:AddRanges(io.Fonts:GetGlyphRangesCyrillic())
        builder:AddText('‚„…†‡€‰‹‘’“”•–—™›№«»→')
        glyphRanges = imgui.ImVector_ImWchar()
        builder:BuildRanges(glyphRanges)
        io.Fonts:Clear()
        io.Fonts:AddFontFromFileTTF(regular, math.floor(16 * fs), nil, glyphRanges[0].Data)
        if doesFileExist(bold) then
            fontBold = io.Fonts:AddFontFromFileTTF(bold, math.floor(19 * fs), nil, glyphRanges[0].Data)
        end
    end
    applyStyle()
end)

local function articleTitle(a)
    local s = a.doc .. ' ' .. a.n
    if a.w then s = s .. '   розыск: ' .. a.w .. ' ур.' end
    if a.f then s = s .. '   штраф: ' .. a.f .. '$' end
    return s
end

local function drawArticle(a)
    colored(CLR.accent, articleTitle(a))
    if a.ch ~= '' then muted(a.ch) end
    text(a.t)
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
end

-------------------------------------------------------------------------------
-- Страницы главного меню
-------------------------------------------------------------------------------
local PAGES = { 'Главная', 'Отыгровки', 'Биндер', 'Законы', 'ИИ-напарник', 'Настройки' }

local function pageMain()
    header('Профиль сотрудника')
    field('Имя и фамилия персонажа. Если оставить пустым, возьмётся ник', 'name', buf.name)
    field('Звание', 'rank', buf.rank)
    muted('Подразделение')
    for i, d in ipairs(DEPTS) do
        if i > 1 then imgui.SameLine() end
        if toggleButton(d .. '##dept', cfg.profile.dept == d, S(96)) then cfg.profile.dept = d end
    end
    imgui.Checkbox('Женский персонаж (отыгровки в женском роде)', buf.female)
    muted('Пауза между строками отыгровки, мс')
    imgui.SetNextItemWidth(-1)
    imgui.SliderInt('##delay', buf.delay, 500, 3000)

    header('Основные команды')
    row('/fh', 'это меню')
    row('/sus [id]', 'умный розыск: выбор статьи УК из списка')
    row('/ask [вопрос]', 'задать вопрос ИИ-напарнику')
    row('/ai или ' .. cfg.ai.key, 'показать или скрыть окно напарника')
    row('/laws [текст]', 'поиск по законам')
    row('/ud [id]', 'показать удостоверение')
    row('/mm [номер]', 'фраза в мегафон')
    row('/qsm', 'тревога в рацию с названием района')
    row('/mark [id], /rb', 'поставить и убрать метку на игрока')
    row('ПКМ + колёсико', 'быстрое меню по игроку в прицеле')
    muted('Любая команда с отыгровкой работает и без неё: добавьте sp в конец, например /cuffsp.')

    header('База законов')
    if laws.loaded then
        text('Загружено статей: ' .. #laws.flat .. '. Версия от ' .. laws.version .. '.')
    else
        colored(CLR.warn, 'База ещё не загружена.')
    end
    if imgui.Button('Проверить обновления базы') then checkLaws() end
end

local function pageRp()
    muted('Нажмите на команду, чтобы изменить её текст. Каждая строка отправляется в чат отдельно.')
    imgui.Spacing()
    for _, k in ipairs(RP_ORDER) do
        local def = DEFAULT_RP[k]
        if imgui.CollapsingHeader(def.title .. '   ' .. def.usage .. '##rp' .. k) then
            imgui.Checkbox('Отыгрывать перед командой##' .. k, buf.rpOn[k])
            area('rp' .. k, buf.rp[k], 84)
            if imgui.Button('Вернуть стандартный текст##' .. k) then setBuf(buf.rp[k], joinLines(def.lines)) end
            imgui.Spacing()
        end
    end
    header('Метки в тексте')
    row('{target}', 'имя игрока, на которого направлена команда')
    row('{name}', 'ваше имя')
    row('{rank}', 'ваше звание')
    row('{dept}', 'ваше подразделение')
    row('{arg}', 'то, что написано после id в команде')
    row('{a}', 'окончание «а» для женского персонажа: снял{a}')
    row('[он|она]', 'выбор слова по полу персонажа')
end

local function pageBinds()
    header('Свои команды')
    muted('Имя команды пишется без косой черты. Каждая строка текста отправляется в чат отдельно.')
    local remove
    for i = 1, #cfg.binds do
        imgui.PushIDInt(i)
        imgui.AlignTextToFramePadding()
        text('/')
        imgui.SameLine()
        imgui.SetNextItemWidth(S(180))
        imgui.InputText('##cmd', buf.bindCmd[i], ffi.sizeof(buf.bindCmd[i]))
        imgui.SameLine()
        if imgui.Button('Удалить') then remove = i end
        area('lines', buf.bindLines[i], 70)
        imgui.Spacing()
        imgui.PopID()
    end
    if remove then
        table.remove(cfg.binds, remove); syncBuffers()
    end
    if imgui.Button('Добавить команду') then
        cfg.binds[#cfg.binds + 1] = { cmd = 'bind' .. (#cfg.binds + 1), lines = { '/me ...' } }
        syncBuffers()
    end

    header('Мегафон')
    muted('Одна фраза на строку. Вызов: /mm и номер строки.')
    area('mega', buf.mega, 110)

    header('Тревога QSM')
    muted('Строки для команды /qsm. Метка {zone} заменяется на название района.')
    area('qsm', buf.qsm, 60)
end

local lawCache = { q = nil, list = {} }
local function pageLaws()
    field('Поиск по законам', 'lawq', buf.lawq, 'Например: обыск без ордера или 8.1')
    imgui.Spacing()
    local q = getBuf(buf.lawq)
    if not laws.loaded then
        colored(CLR.warn, 'База законов не загружена. Откройте «Главная» и нажмите «Проверить обновления базы».')
        return
    end
    if q == '' then
        header('Документы в базе')
        for _, d in ipairs(laws.docs) do
            row(d.id, d.title .. ' (' .. #(d.articles or {}) .. ')')
        end
        if #laws.changes > 0 then
            header('Последнее обновление: ' .. laws.version)
            for _, c in ipairs(laws.changes) do text(c) end
        end
        return
    end
    if lawCache.q ~= q then
        local list
        if q:match('^%d+[%.%d]*$') then
            list = {}
            for _, a in ipairs(laws.flat) do
                if a.n == q or a.n:sub(1, #q + 1) == q .. '.' then list[#list + 1] = a end
                if #list >= 40 then break end
            end
        else
            list = searchLaws(q, 25, false)
        end
        lawCache.q, lawCache.list = q, list
    end
    if #lawCache.list == 0 then muted('Ничего не найдено.') end
    for _, a in ipairs(lawCache.list) do drawArticle(a) end
end

local function pageAI()
    header('ИИ-напарник')
    imgui.Checkbox('Включить напарника', buf.aiOn)
    muted('Как часто можно обращаться к ИИ, секунд')
    imgui.SetNextItemWidth(-1)
    imgui.SliderInt('##interval', buf.interval, 3, 30)
    row('Состояние', ai.status .. (ai.provider ~= '' and (' (' .. ai.provider .. ')') or ''))
    local names = {}
    for _, p in ipairs(providers) do names[#names + 1] = p.name end
    row('Сервисы', table.concat(names, ' → '))
    if imgui.Button('Проверить связь с ИИ') then
        showPartner[0] = true
        pushEvent('Тестовое сообщение: сотрудник остановил автомобиль для проверки документов.', true)
        askAI('Проверка связи: что делать при остановке автомобиля?')
    end

    header('Свой ключ (необязательно)')
    muted('Напарник работает и без ключа. Свой ключ Groq или Gemini нужен только для большей стабильности.')
    field('Адрес API', 'curl', buf.custom_url, 'https://api.groq.com/openai/v1/chat/completions')
    field('Ключ', 'ckey', buf.custom_key, nil, imgui.InputTextFlags.Password)
    field('Модель', 'cmodel', buf.custom_model, 'llama-3.3-70b-versatile')
end

local function pageSettings()
    header('Общие')
    imgui.Checkbox('Автоматически обновлять скрипт', buf.upd)

    header('Фильтр чата')
    imgui.Checkbox('Скрывать строки с этими словами', buf.filterOn)
    muted('Одно слово или фраза на строку.')
    area('filter', buf.filter, 70)

    header('Автовход')
    colored(CLR.warn, 'Используйте на свой риск. Пароль хранится на вашем компьютере в открытом виде, а автоматический вход может нарушать правила сервера.')
    imgui.Checkbox('Включить автовход', buf.alOn)
    field('Пароль', 'pass', buf.pass, nil, imgui.InputTextFlags.Password)
end

local PAGE_DRAW = { pageMain, pageRp, pageBinds, pageLaws, pageAI, pageSettings }

imgui.OnFrame(function() return cfg ~= nil and showMenu[0] end, function()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(S(860), S(580)), imgui.Cond.FirstUseEver)
    imgui.Begin('Настройки помощника##main', showMenu, imgui.WindowFlags.NoCollapse)

    local footer = imgui.GetFrameHeightWithSpacing() + S(4)
    imgui.BeginChild('##nav', imgui.ImVec2(S(190), -footer), true)
    if fontBold then imgui.PushFont(fontBold) end
    colored(CLR.accent, 'MVD Helper')
    if fontBold then imgui.PopFont() end
    muted(cfg.profile.dept .. ', версия ' .. VERSION)
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.PushStyleVarVec2(imgui.StyleVar.ButtonTextAlign, imgui.ImVec2(0.08, 0.5))
    for i, name in ipairs(PAGES) do
        if toggleButton(name .. '##nav', page == i, -1, S(36)) then page = i end
    end
    imgui.PopStyleVar(1)
    imgui.EndChild()
    imgui.SameLine()
    imgui.BeginChild('##page', imgui.ImVec2(0, -footer), true)
    PAGE_DRAW[page]()
    imgui.EndChild()

    if imgui.Button('Сохранить настройки', imgui.ImVec2(S(210), 0)) then applyBuffers() end
    imgui.SameLine()
    imgui.AlignTextToFramePadding()
    muted('Изменения начнут действовать после сохранения.')
    imgui.End()
end)

-------------------------------------------------------------------------------
-- Окно напарника (без курсора, поверх игры)
-------------------------------------------------------------------------------
local function label(s) colored(CLR.accent, s) end

imgui.OnFrame(function() return cfg ~= nil and showPartner[0] and cfg.ai.enabled and not isPauseMenuActive() end, function(player)
    player.HideCursor = not (showMenu[0] or showSus[0] or showQuick[0])
    local pc = cfg.partner
    imgui.SetNextWindowPos(imgui.ImVec2(pc.x, pc.y), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(imgui.ImVec2(pc.w, pc.h), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowBgAlpha(0.86)
    imgui.Begin('Напарник##partner', nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoFocusOnAppearing)
    local pos, size = imgui.GetWindowPos(), imgui.GetWindowSize()
    pc.x, pc.y, pc.w, pc.h = pos.x, pos.y, size.x, size.y

    if ai.pending then
        muted(ai.status)
    elseif ai.provider ~= '' then
        muted('Ответил: ' .. ai.provider)
    else
        muted(ai.status)
    end
    imgui.Separator()

    local r = ai.result
    if type(r) ~= 'table' then
        text('Жду событий в чате. Подсказки появятся, когда вы начнёте работать с гражданином.')
        muted('Свой вопрос можно задать командой /ask.')
    else
        local situation, nextStep, warning, command = sval(r.situation), sval(r.next), sval(r.warning), sval(r.command)
        if situation ~= '' then label('Ситуация'); text(situation) end
        if type(r.checklist) == 'table' and #r.checklist > 0 then
            label('Порядок действий')
            for _, c in ipairs(r.checklist) do
                if type(c) == 'table' then
                    if c.done == true then
                        colored(CLR.good, '+ ' .. sval(c.step))
                    else
                        colored(CLR.bad, '– ' .. sval(c.step))
                    end
                end
            end
        end
        if nextStep ~= '' then label('Что делать сейчас'); text(nextStep) end
        if warning ~= '' then colored(CLR.warn, 'Внимание'); text(warning) end
        local shown = false
        if type(r.refs) == 'table' then
            for _, ref in ipairs(r.refs) do
                if type(ref) == 'table' and sval(ref.doc) ~= '' then
                    if not shown then label('Основание'); shown = true end
                    local doc, n = sval(ref.doc), sval(ref.n)
                    text(doc .. ' ' .. n .. (sval(ref.why) ~= '' and (': ' .. sval(ref.why)) or ''))
                    for _, a in ipairs(laws.flat) do
                        if a.doc == doc and a.n == n then
                            muted('«' .. cut(a.t, 240) .. '»')
                            break
                        end
                    end
                end
            end
        end
        if not shown and #ai.refs > 0 then
            label('Похожие статьи')
            for i = 1, math.min(4, #ai.refs) do
                local a = ai.refs[i]
                text(a.doc .. ' ' .. a.n .. ': ' .. cut(a.t, 170))
            end
        end
        if command ~= '' then label('Команда'); colored(CLR.text, command) end
    end
    imgui.End()
end)

-------------------------------------------------------------------------------
-- Умный розыск: слева список статей, справа выбранная статья
-------------------------------------------------------------------------------
local sus = { q = nil, ver = nil, list = {}, sel = nil, nick = '' }

local function openSus(id)
    susTarget = id
    local okNick, nick = pcall(sampGetPlayerNickname, id)
    sus.nick = (okNick and type(nick) == 'string') and nick or 'игрок не найден'
    setBuf(buf.susq, '')
    showQuick[0] = false
    showSus[0] = true
end

local function issueWanted(a)
    if not a or not a.w or susTarget < 0 then return end
    local reason = to1251(a.doc .. ' ' .. a.n)
    showSus[0] = false
    sampProcessChatInput(string.format('/su %d %d %s', susTarget, a.w, reason))
end

imgui.OnFrame(function() return cfg ~= nil and showSus[0] end, function()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(S(860), S(520)), imgui.Cond.FirstUseEver)
    local nick = sus.nick
    imgui.Begin('Умный розыск##sus', showSus, imgui.WindowFlags.NoCollapse)
    row('Подозреваемый', nick .. ' [' .. susTarget .. ']')
    field('Фильтр по номеру статьи или словам', 'susq', buf.susq, 'Например: 8.1 или похищение')

    local q = getBuf(buf.susq)
    if sus.q ~= q or sus.ver ~= laws.version then
        sus.q, sus.ver = q, laws.version
        sus.list = wantedArticles(q)
        sus.sel = sus.list[1]
    end

    if not laws.loaded then
        colored(CLR.warn, 'База законов не загружена.')
    elseif #sus.list == 0 then
        muted('Подходящих статей нет.')
    else
        imgui.BeginChild('##suslist', imgui.ImVec2(S(340), 0), true)
        for i, a in ipairs(sus.list) do
            local title = a.doc .. ' ' .. a.n .. '  •  ' .. a.w .. ' ур.  •  ' .. cut((a.t:gsub('%s+', ' ')), 44)
            if imgui.Selectable(title .. '##s' .. i, sus.sel == a) then sus.sel = a end
        end
        imgui.EndChild()
        imgui.SameLine()
        imgui.BeginChild('##susview', imgui.ImVec2(0, 0), true)
        local a = sus.sel
        if a then
            header(a.doc .. ' ' .. a.n)
            if a.ch ~= '' then muted(a.ch) end
            row('Уровень розыска', tostring(a.w))
            if a.f then row('Штраф', a.f .. '$') end
            imgui.Spacing()
            text(a.t)
            imgui.Spacing()
            if imgui.Button('Выдать розыск: ' .. a.w .. ' ур.', imgui.ImVec2(-1, 0)) then issueWanted(a) end
            muted('Будет отправлено: /su ' .. susTarget .. ' ' .. a.w .. ' ' .. a.doc .. ' ' .. a.n)
        end
        imgui.EndChild()
    end
    imgui.End()
end)

-------------------------------------------------------------------------------
-- Быстрое меню по игроку
-------------------------------------------------------------------------------
local QUICK = { 'cuff', 'uncuff', 'hold', 'putpl', 'eject', 'search', 'ticket', 'takelic', 'arrest', 'clear' }
imgui.OnFrame(function() return cfg ~= nil and showQuick[0] end, function()
    local mx, my = getCursorPos()
    imgui.SetNextWindowPos(imgui.ImVec2(mx, my), imgui.Cond.Appearing)
    local nick = quickTarget >= 0 and sampIsPlayerConnected(quickTarget) and sampGetPlayerNickname(quickTarget) or 'игрок'
    imgui.Begin(nick .. ' [' .. quickTarget .. ']##quick', showQuick, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoCollapse)
    for _, k in ipairs(QUICK) do
        if imgui.Button(DEFAULT_RP[k].title .. '##q' .. k, imgui.ImVec2(S(220), 0)) then
            showQuick[0] = false
            if k == 'ticket' or k == 'takelic' then
                sampSetChatInputEnabled(true)
                sampSetChatInputText('/' .. k .. ' ' .. quickTarget .. ' ')
            else
                makeRpHandler(k, true)(tostring(quickTarget))
            end
        end
    end
    if imgui.Button('Умный розыск##qsus', imgui.ImVec2(S(220), 0)) then
        openSus(quickTarget)
    end
    imgui.Separator()
    muted('Мегафон')
    for i, m in ipairs(cfg.megaphone) do
        if imgui.Button(cut(m, 34) .. '##mm' .. i, imgui.ImVec2(S(220), 0)) then say('/m ' .. m) showQuick[0] = false end
    end
    imgui.End()
end)

-------------------------------------------------------------------------------
-- Команды
-------------------------------------------------------------------------------
local bindRegistered = {}
registerBinds = function()
    for _, c in ipairs(bindRegistered) do sampUnregisterChatCommand(c) end
    bindRegistered = {}
    for _, b in ipairs(cfg.binds) do
        if b.cmd and b.cmd ~= '' and not DEFAULT_RP[b.cmd] then
            sampRegisterChatCommand(b.cmd, function(raw)
                local ctx = { arg = toUtf(raw or '') }
                local id = parseIdArgs(raw or '')
                if id and sampIsPlayerConnected(id) then ctx.target = rpName(sampGetPlayerNickname(id)) end
                playLines(b.lines, ctx)
            end)
            bindRegistered[#bindRegistered + 1] = b.cmd
        end
    end
end

local markBlip
local function zoneName()
    local x, y, z = getCharCoordinates(PLAYER_PED)
    local key = getNameOfZone(x, y, z)
    local name = key and getGxtText(key) or ''
    if name == '' then name = string.format('%.0f, %.0f', x, y) else name = toUtf(name) end
    return name
end

local function registerCommands()
    for _, k in ipairs(RP_ORDER) do
        sampRegisterChatCommand(k, makeRpHandler(k, true))
        sampRegisterChatCommand(k .. 'sp', makeRpHandler(k, false))
    end
    sampRegisterChatCommand('fh', function() showMenu[0] = not showMenu[0] end)
    sampRegisterChatCommand('ai', function()
        showPartner[0] = not showPartner[0]
        msg('Окно напарника ' .. (showPartner[0] and 'показано' or 'скрыто'))
    end)
    sampRegisterChatCommand('ask', function(raw)
        if not raw or raw == '' then msg('Используйте: /ask [вопрос]') return end
        showPartner[0] = true
        askAI(toUtf(raw))
    end)
    sampRegisterChatCommand('sus', function(raw)
        local id = parseIdArgs(raw or '')
        if not id or not sampIsPlayerConnected(id) then msg('Используйте: /sus [id]') return end
        openSus(id)
    end)
    sampRegisterChatCommand('laws', function(raw)
        setBuf(buf.lawq, toUtf(raw or '')); page = 4; showMenu[0] = true
    end)
    sampRegisterChatCommand('mm', function(raw)
        local n = tonumber(raw)
        if not n or not cfg.megaphone[n] then
            for i, m in ipairs(cfg.megaphone) do msg(i .. '. ' .. m) end
            return
        end
        say('/m ' .. cfg.megaphone[n])
    end)
    sampRegisterChatCommand('qsm', function()
        playLines(cfg.qsm, { zone = zoneName() })
    end)
    sampRegisterChatCommand('ud', function(raw)
        local id = parseIdArgs(raw or '')
        local lines = { '/me достал{a} удостоверение из нагрудного кармана и раскрыл{a} его', '/do Удостоверение: {name}, {rank}, {deptfull}.' }
        local final = nil
        if id and sampIsPlayerConnected(id) then
            lines[#lines + 1] = '/me показал{a} удостоверение {target}'
        end
        playLines(lines, { target = id and sampIsPlayerConnected(id) and rpName(sampGetPlayerNickname(id)) or nil }, final)
    end)
    sampRegisterChatCommand('mark', function(raw)
        local id = parseIdArgs(raw or '')
        if not id then msg('Используйте: /mark [id]') return end
        local ok, ped = sampGetCharHandleBySampPlayerId(id)
        if not ok then msg('Игрок не в зоне прорисовки.') return end
        if markBlip then removeBlip(markBlip) end
        markBlip = addBlipForChar(ped)
        msg('Метка на игрока ' .. sampGetPlayerNickname(id) .. ' поставлена. /rb чтобы убрать.')
    end)
    sampRegisterChatCommand('rb', function()
        if markBlip then removeBlip(markBlip) markBlip = nil msg('Метка убрана.') end
    end)
    registerBinds()
end

-------------------------------------------------------------------------------
-- События
-------------------------------------------------------------------------------
function sampev.onServerMessage(color, text)
    if not cfg then return end
    local t = toUtf(text)
    if cfg.filter.enabled then
        for _, w in ipairs(cfg.filter.words) do
            if t:find(w, 1, true) then return false end
        end
    end
    pushEvent(t)
end

function sampev.onSendChat(m)
    if not cfg then return end
    pushEvent('[Я] ' .. toUtf(m), true)
end

function sampev.onSendCommand(c)
    if not cfg then return end
    local t = toUtf(c)
    local low = ulower(t)
    if low:find('^/me') or low:find('^/do') or low:find('^/su ') or low:find('^/cuff') or low:find('^/search')
        or low:find('^/ticket') or low:find('^/arrest') or low:find('^/putpl') or low:find('^/takelic')
        or low:find('^/m ') or low:find('^/r ') or low:find('^/eject') or low:find('^/pull') or low:find('^/clear') then
        pushEvent('[Я] ' .. t, true)
    end
end

local loginSent = false
function sampev.onShowDialog(id, style, title, b1, b2, text)
    if not cfg then return end
    if cfg.autologin.enabled and cfg.autologin.password ~= '' and style == 3 and not loginSent then
        local t = ulower(toUtf(title) .. ' ' .. toUtf(text))
        if t:find('авториз') or t:find('пароль') then
            loginSent = true
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 1, -1, to1251(cfg.autologin.password))
            end)
            return false
        end
    end
end

-------------------------------------------------------------------------------
-- main
-------------------------------------------------------------------------------
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    if not doesDirectoryExist(DIR) then createDirectory(DIR) end
    if not doesDirectoryExist(getWorkingDirectory() .. '/config') then createDirectory(getWorkingDirectory() .. '/config') end

    local prevTrace = readFile(TRACE_PATH)
    local crashed = prevTrace and prevTrace ~= '' and not prevTrace:find('ok$')
    if crashed then
        log('Прошлый запуск завершился аварийно. Последнее состояние: ' .. prevTrace)
        local f = io.open(DIR .. '/crashes.txt', 'a')
        if f then f:write(os.date('%Y-%m-%d '), prevTrace, '\n') f:close() end
    end
    writeFile(TRACE_PATH, 'start')

    loadCfg()
    syncBuffers()
    loadProviders()
    loadLaws()
    registerCommands()

    msg('Загружен v' .. VERSION .. '. Меню: /fh, окно напарника: ' .. cfg.ai.key .. ' или /ai.')

    if crashed then msg('Прошлый раз игра закрылась аварийно. Запись об этом сохранена в moonloader/MVDHelper/crashes.txt.') end

    checkLaws()
    checkProviders()
    if cfg.autoupdate then checkUpdate() end

    local lastNearby = 0
    local partnerKey = vk['VK_' .. cfg.ai.key] or vk.VK_F3
    while true do
        wait(0)
        local now = clock()
        if now - lastNearby > 2 then
            trace('bg', 'nearby')
            updateNearby()
            trace('bg', '-')
            lastNearby = now
        end
        trace('ui', (showMenu[0] and ('menu' .. page) or '') .. (showSus[0] and '+sus' or '') .. (showQuick[0] and '+quick' or '') .. (showPartner[0] and '+partner' or ''))

        if not sampIsChatInputActive() and not sampIsDialogActive() and not isSampfuncsConsoleActive() then
            if wasKeyPressed(partnerKey) then showPartner[0] = not showPartner[0] end
            if isKeyDown(vk.VK_RBUTTON) and wasKeyPressed(vk.VK_MBUTTON) then
                local ok, ped = getCharPlayerIsTargeting(PLAYER_HANDLE)
                if ok then
                    local ok2, id = sampGetPlayerIdByCharHandle(ped)
                    if ok2 then quickTarget = id; showQuick[0] = true end
                end
            end
        end

        if cfg.ai.enabled and ai.dirty and not ai.pending
            and now - ai.lastCall >= cfg.ai.interval and now - ai.lastEvent >= 1.5 then
            askAI()
        end
    end
end

function onScriptTerminate(s)
    if s == thisScript() then
        if cfg then saveCfg() end
        writeFile(TRACE_PATH, os.date('%H:%M:%S') .. ' ok')
    end
end
