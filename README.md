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
