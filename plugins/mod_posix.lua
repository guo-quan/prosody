
local want_pposix_version = "0.3.0";

local pposix = assert(require "util.pposix");
if pposix._VERSION ~= want_pposix_version then module:log("warn", "Unknown version (%s) of binary pposix module, expected %s", tostring(pposix._VERSION), want_pposix_version); end

local signal = select(2, pcall(require, "util.signal"));
if type(signal) == "string" then
	module:log("warn", "Couldn't load signal library, won't respond to SIGTERM");
end

local config_get = require "core.configmanager".get;
local logger_set = require "util.logger".setwriter;

module.host = "*"; -- we're a global module

-- Don't even think about it!
module:add_event_hook("server-starting", function ()
		if pposix.getuid() == 0 and not config_get("*", "core", "run_as_root") then
			module:log("error", "Danger, Will Robinson! Prosody doesn't need to be run as root, so don't do it!");
			module:log("error", "For more information on running Prosody as root, see http://prosody.im/doc/root");
			_G.prosody_shutdown("Refusing to run as root");
		end
	end);

local pidfile_written;

local function remove_pidfile()
	if pidfile_written then
		os.remove(pidfile_written);
		pidfile_written = nil;
	end
end

local function write_pidfile()
	if pidfile_written then
		remove_pidfile();
	end
	local pidfile = config_get("*", "core", "pidfile");
	if pidfile then
		local pf, err = io.open(pidfile, "w+");
		if not pf then
			module:log("error", "Couldn't write pidfile; %s", err);
		else
			pf:write(tostring(pposix.getpid()));
			pf:close();
			pidfile_written = pidfile;
		end
	end
end

local syslog_opened 
function syslog_sink_maker(config)
	if not syslog_opened then
		pposix.syslog_open("prosody");
		syslog_opened = true;
	end
	local syslog, format = pposix.syslog_log, string.format;
	return function (name, level, message, ...)
			if ... then
				syslog(level, format(message, ...));
			else
				syslog(level, message);
			end
		end;
end
require "core.loggingmanager".register_sink_type("syslog", syslog_sink_maker);

if not config_get("*", "core", "no_daemonize") then
	local function daemonize_server()
		local ok, ret = pposix.daemonize();
		if not ok then
			module:log("error", "Failed to daemonize: %s", ret);
		elseif ret and ret > 0 then
			os.exit(0);
		else
			module:log("info", "Successfully daemonized to PID %d", pposix.getpid());
			write_pidfile();
		end
	end
	module:add_event_hook("server-starting", daemonize_server);
else
	-- Not going to daemonize, so write the pid of this process
	write_pidfile();
end

module:add_event_hook("server-stopped", remove_pidfile);

-- Set signal handler
if signal.signal then
	signal.signal("SIGTERM", function ()
		module:log("warn", "Received SIGTERM...");
		_G.unlock_globals();
		if _G.prosody_shutdown then
			_G.prosody_shutdown("Received SIGTERM");
		else
			module:log("warn", "...no prosody_shutdown(), ignoring.");
		end
		_G.lock_globals();
	end);
end
