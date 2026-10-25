# Security

TV Display asks for Screen Recording (and, for TV sound, audio capture) permission on the Mac, so security problems matter. Thank you for reporting them responsibly.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead: go to the [Security tab](https://github.com/raufhm/tv-display/security) and click **Report a vulnerability**.

Include what you found, how to reproduce it, and which versions of the Mac app, macOS, the TV app and Android you used. You should get a reply within a week.

## What's in scope

- Anything that lets a device other than the chosen TV receive the picture or sound
- Anything that lets the TV, or anything else on the network, run code on or read data from the Mac
- Crashes of the TV app or Mac app caused by malformed network data

## Known limitations (by design, for now)

- The stream between the Mac and the TV is **not encrypted**. Anyone on the same local network who can capture its traffic could see what's on the TV display. Only use it on networks you trust.
- The TV accepts a connection from any device on the local network on port 7777, and the newest connection takes over the screen. Since version 1.1 the TV listens in the background from boot and announces itself on the network (Bonjour), so this applies whenever the TV is on.

Proposals to add pairing or encryption are welcome as issues.
