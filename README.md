# Kevin TV for Roku

A sideloaded Roku (SceneGraph) app that wraps an Xtream-style IPTV service: live channels, movies, series,
search, profiles and resume points.

## Install (sideload)

1. Put the Roku in developer mode (Home ×3, Up ×2, Right, Left, Right, Left, Right) and note its IP address.
2. Optional: copy `data/personal.example.json` to `data/personal.json` and fill in your login so the app starts
   signed in. That file is git-ignored on purpose. Without it, enter the login in the app's Settings.
3. Zip the app (the manifest must be at the top level of the zip):

       zip -r KevinTV.zip manifest source components images data -x data/personal.example.json

4. Open `http://<roku-ip>` in a browser and upload the zip.

## Audio on Roku players (Premiere, Express, Stick)

Roku **TVs** decode Dolby Digital (AC3 / EAC3) themselves. Roku **players** such as the Premiere 3920X do not:
they decode AAC and MP3 and only *pass through* Dolby and DTS to the TV or soundbar. If the TV does not accept
Dolby, or the Roku's audio setting is forced to Stereo, those streams play with a picture and no sound.

What the app does (since 1.0.14): when a file has several audio tracks it quietly picks one this device can
play (AAC preferred). It shows no audio messages and never makes extra requests to the provider. A file whose
only audio track is Dolby Digital Plus or DTS plays without sound on a Roku player when the TV won't accept that
format (for example the LG UK6190 tested here).

What to check on the Roku: Settings › Audio › HDMI (or "Digital output format") → Auto detect, and
Audio mode → Auto.

## Debug log

    telnet <roku-ip> 8085

Lines starting with `[KTV] audio` show the device's answer for each codec and what the player chose, e.g.
`[KTV] audio CanDecodeAudio(ac3)=false -> no`.

## Converter on the Mac (for movies with no sound)

`helper/kevintv_helper.py` runs on a Mac on the home network. When the Roku finds no sound it can play in a movie or
episode, it switches to the converter, which fetches the file from the provider once, copies the video untouched and
converts only the sound to stereo AAC. Titles that needed it are remembered (whole series at once), so next time
they go straight to the converter.

Start it: double-click `helper/start-helper.command` (the first time: right-click › Open, and allow incoming
connections if macOS asks). It reads the login from `data/personal.json` and needs ffmpeg. Leave the window open
while watching; it keeps the Mac awake during playback. On the Roku: Settings › PC address = the address the window
shows (for example `192.168.68.120:8766`).

Made for a 1-stream plan: one conversion at a time, a 4-second pause before connecting so the Roku's own stream has
closed, no automatic retries, and the provider connection is closed when the Roku stops asking for 2 minutes. It
refuses to convert while a VPN is connected, so provider traffic never goes through a work VPN (`--allow-vpn`
overrides). It only answers devices on the home network. Converted pieces are kept in a temporary folder and
deleted when the next title starts or the converter quits (a 3-hour movie can take several GB meanwhile).
