dofile("table_show.lua")
dofile("urlcode.lua")
local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
JSON = (loadfile "JSON.lua")()

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = os.getenv("concurrency")
local item_names_newline = os.getenv("item_names_newline")
local item_names = {}
local item_type = nil
local item_name = nil
local item_value = nil

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

for s in string.gmatch(item_names_newline, "([^\n]+)") do
  item_names[string.lower(s)] = true
end

local retry_url = false

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore] = true
end

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
print('queuing' , item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  value = string.match(url, "^https://www%.dpreview%.com/forums/thread/([0-9]+)$")
  type_ = "thread"
  if not value then
    value = string.match(url, "^https://www%.dpreview%.com/forums/post/([0-9]+)$")
    type_ = "post"
  end
  if not value and item_names["url:" .. string.lower(url)] then
    value = url
    type_ = "url"
  end
  if value then
    item_type = type_
    item_value = value
    item_name_new = item_type .. ":" .. item_value
    if item_name_new ~= item_name then
      ids = {}
      ids[value] = true
      abortgrab = false
      initial_allowed = false
      tries = 0
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parenturl)
  if ids[url]
    or ids[string.lower(url)]
    or url == item_value
    or string.lower(url) == item_value then
    return true
  end

  if string.match(url, "^https?://m%.dpreview%.com/")
    or string.match(url, "/forums/reply")
    or string.match(url, "/forums/thread/[0-9]+/[0-9]+$")
    or string.match(url, "^https?://login%.dpreview%.com/")
    or string.match(url, "^https?://[^/]*dpreview%.com/feedback%?")
    or string.match(url, "[%?&]JumpToComment=") then
    return false
  end

  local type_, num = string.match(url, "/forums/([a-z]+)/([0-9]+)")
  if (type_ == "thread" and item_type ~= "thread")
    or (type_ == "post" and item_type ~= "post") then
    return false
  end
  if num and ids[num] then
    return true
  end

  local num = string.match(url, "^https?://[^/]*dpreview.com/members/([0-9]+)")
  if num then
    discover_item(discovered_items, "member:" .. num)
    return false
  end

  if string.match(url, "^https?://[^/]*dpreview%.com/") then
    discover_item(discovered_items, "url:" .. url)
    return false
  else
    discover_item(discovered_outlinks, url)
    return false
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if allowed(url, parent["url"]) and not processed(url) then
    addedtolist[url] = true
    return true
  end

  --[[if html == 0 then
    discover_item(discovered_outlinks, url)
  end]]

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  
  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function decode_codepoint(newurl)
    newurl = string.gsub(
      newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
      function (s)
        return unicode_codepoint_as_utf8(tonumber(s, 16))
      end
    )
    return newurl
  end

  local function check(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "%s") then
      for s in string.gmatch(newurl, "([^%s]+)") do
        check(s)
      end
      return nil
    end
    local origurl = url
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and allowed(url_, origurl) then
      table.insert(urls, { url=url_ })
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  if allowed(url)
    and status_code < 300
    and (
      string.match(url, "^https?://dpreview%.com/")
      or string.match(url, "^https?://www%.dpreview%.com/")
    ) then
    html = read_file(file)
    html = string.gsub(html, "\\", "")
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      check(newurl)--checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      check(newurl)--checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      check(newurl)--checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      check(newurl)--checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      check(newurl)--checknewurl(newurl)
    end
    html = string.gsub(html, "&gt;", ">")
    html = string.gsub(html, "&lt;", "<")
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      check(newurl)--checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  find_item(url["url"])
  if not item_name then
    error("No item name found.")
  end
  if status_code == 429 then
    io.stdout:write("Banned! Sleeping 400 seconds.\n")
    io.stdout:flush()
    os.execute("sleep 400")
  end
  if status_code ~= 200 and status_code ~= 301 then
    abort_item()
  end
  if abortgrab then
    return false
  end
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()

  if killgrab then
    return wget.actions.ABORT
  end

  find_item(url["url"])

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    --[[if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end]]
    if status_code == 301 then
      discover_item(discovered_items, "url:" .. newloc)
      return wget.actions.EXIT
    end
    abort_item()
  end

  if string.match(url["url"], "^https?://www%.dpreview%.com/")
    or string.match(url["url"], "^https?://dpreview%.com/") then
    os.execute("sleep " .. tostring(concurrency))
  end
  
  if status_code == 200 then
    downloaded[url["url"]] = true
    downloaded[string.gsub(url["url"], "https?://", "http://")] = true
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0
    or status_code ~= 200 then
    io.stdout:write("Server returned bad response. Skipping.\n")
    io.stdout:flush()
    abort_item()
    return wget.actions.EXIT
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 10
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and JSON:decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["dpreview-fb26p7vylgwggbjv"] = discovered_items,
    ["urls-9q5jsj529xqzbzzx"] = discovered_outlinks
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 100 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end

