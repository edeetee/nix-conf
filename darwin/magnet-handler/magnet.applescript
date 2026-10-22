-- Default handler for magnet: URLs on this Mac.
--
-- Compiled into "Add to Transmission.app" and registered for the magnet scheme
-- by darwin/magnet-handler.nix. It has to be an AppleScript app: LaunchServices
-- delivers a clicked URL to a bundle as a kAEGetURL Apple Event, never as argv
-- (verified — a shell-script bundle is launched with zero arguments), and
-- `on open location` is the only way to receive it without writing a Cocoa app.
--
-- The work happens in ~/.local/bin/magnet-add so this file rarely changes.

on open location theURL
	try
		do shell script "$HOME/.local/bin/magnet-add " & quoted form of theURL
	on error errMsg
		display notification errMsg with title "Add to Transmission"
	end try
end open location
