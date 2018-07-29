
local irc_users = {}

local old_chat_send_player = minetest.chat_send_player
minetest.chat_send_player = function(name, message)
	for nick, loggedInAs in pairs(irc_users) do
		if name == loggedInAs and not minetest.get_player_by_name(name) then
			irc:say(nick, message)
		end
	end
	return old_chat_send_player(name, message)
end

irc:register_hook("NickChange", function(user, newNick)
	for nick, player in pairs(irc_users) do
		if nick == user.nick then
			irc_users[newNick] = irc_users[user.nick]
			irc_users[user.nick] = nil
		end
	end
end)

irc:register_hook("OnPart", function(user, channel, reason)
	irc_users[user.nick] = nil
end)

irc:register_hook("OnKick", function(user, channel, target, reason)
	irc_users[target] = nil
end)

irc:register_hook("OnQuit", function(user, reason)
	irc_users[user.nick] = nil
end)

irc:register_bot_command("login", {
	params = "<username> <password>",
	description = "Login as a user to run commands",
	func = function(user, args)
		if args == "" then
			return false, "You need a username and password."
		end
		local playerName, password = args:match("^(%S+)%s(.+)$")
		if not playerName then
			return false, "Player name and password required."
		end
		local inChannel = false
		local channel = irc.conn.channels[irc.config.channel]
		if not channel then
			return false, "The server needs to be in its "..
				"channel for anyone to log in."
		end
		for cnick, cuser in pairs(channel.users) do
			if user.nick == cnick then
				inChannel = true
				break
			end
		end
		if not inChannel then
			return false, "You need to be in the server's channel to log in."
		end
		local handler = minetest.get_auth_handler()
		local auth = handler.get_auth(playerName)
		if auth and minetest.check_password_entry(playerName, auth.password, password) then
			minetest.log("action", "User "..user.nick
					.." from IRC logs in as "..playerName)
			irc_users[user.nick] = playerName
			handler.record_login(playerName)
			return true, "You are now logged in as "..playerName
		else
			minetest.log("action", user.nick.."@IRC attempted to log in as "
				..playerName.." unsuccessfully")
			return false, "Incorrect password or player does not exist."
		end
	end
})

irc:register_bot_command("logout", {
	description = "Logout",
	func = function (user, args)
		if irc_users[user.nick] then
			minetest.log("action", user.nick.."@IRC logs out from "
				..irc_users[user.nick])
			irc_users[user.nick] = nil
			return true, "You are now logged off."
		else
			return false, "You are not logged in."
		end
	end,
})

irc:register_bot_command("cmd", {
	params = "<command>",
	description = "Run a command on the server",
	func = function (user, args)
		if args == "" then
			return false, "You need a command."
		end
		if not irc_users[user.nick] then
			return false, "You are not logged in."
		end
		local found, _, commandname, params = args:find("^([^%s]+)%s(.+)$")
		if not found then
			commandname = args
		end
		local command = minetest.chatcommands[commandname]
		if not command then
			return false, "Not a valid command."
		end
		if not minetest.check_player_privs(irc_users[user.nick], command.privs) then
			return false, "Your privileges are insufficient."
		end
		minetest.log("action", user.nick.."@IRC runs "
			..args.." as "..irc_users[user.nick])
		return command.func(irc_users[user.nick], (params or ""))
	end
})

irc:register_bot_command("say", {
	params = "message",
	description = "Say something",
	func = function (user, args)
		if args == "" then
			return false, "You need a message."
		end
		if not irc_users[user.nick] then
			return false, "You are not logged in."
		end
		if not minetest.check_player_privs(irc_users[user.nick], {shout=true}) then
			minetest.log("action", ("%s@IRC tried to say %q as %s"
				.." without the shout privilege.")
					:format(user.nick, args, irc_users[user.nick]))
			return false, "You can not shout."
		end
		minetest.log("action", ("%s@IRC says %q as %s.")
				:format(user.nick, args, irc_users[user.nick]))
		minetest.chat_send_all("<"..irc_users[user.nick].."@IRC> "..args)
		return true, "Message sent successfuly."
	end
})


local storage = minetest.get_mod_storage()

local function check_host_login(user)
	if type(user) ~= "table" then
		local whois = irc.conn:whois(user)
		user = {
			nick = user,
			host = whois.userinfo[4]
		}
	end

	local store = minetest.parse_json(storage:get_string("host_logins")) or {}
	if user.host and store[user.host] then
		local playerName = store[user.host]
		local handler = minetest.get_auth_handler()

		minetest.log("action", "User " .. user.nick ..
				" from IRC logs in as " .. playerName)

		irc_users[user.nick] = playerName

		handler.record_login(playerName)
	end
end

irc:register_hook("OnJoin", function(user, channel)
	if irc.config.nick == user.nick then
		minetest.after(1, function()
			for nick in pairs(irc.conn.channels[irc.config.channel].users) do
				check_host_login(nick)
			end
		end)
	else
		check_host_login(user)
	end
end)

minetest.register_chatcommand("irc_host", {
	privs = { password = true },
	func  = function(name, param)
		local pname, host = string.match(param, "^add ([%a%d_-]+) (.+)$")
		pname = pname or string.match(param, "^remove (.+)$")
		if not pname then
			return false, "Usage: add NAME HOST\nor  remove NAME  or  remove HOST"
		end

		local msg

		local store = minetest.parse_json(storage:get_string("host_logins")) or {}
		if host then
			store[host] = pname
			msg = "Add host for " .. pname .. ": '" .. host .. "'"
		else
			local removed = false
			if store[pname] then
				store[pname] = nil
				removed = true
			end

			for key, val in pairs(store) do
				if val == pname then
					store[key] = nil
					removed = true
				end
			end

			if removed then
				msg = "Removed host mapping matching " .. pname
			else
				msg = "Unable to find host mapping matching " .. pname
			end
		end
		storage:set_string("host_logins", minetest.write_json(store))

		return true, msg
	end
})
