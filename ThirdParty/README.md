# Third-party components

Broadcast Browser builds and runs without any of these. Each one switches on
an output type when it's present. `scripts/build_app.sh` picks them up
automatically.

## Blackmagic DeckLink / UltraStudio (SDI & HDMI output)

DeckLink support is compiled from Blackmagic's **Desktop Video SDK** headers.
Blackmagic's license doesn't let us download or redistribute the SDK for you.

1. Download the **Desktop Video SDK** from
   https://www.blackmagicdesign.com/developer (Products › Capture and Playback).
   It is free but needs a registration form.
2. Copy the SDK's `Mac/include` folder here, so that this file exists:
   `ThirdParty/DeckLinkSDK/include/DeckLinkAPI.h`.
   `DeckLinkAPIDispatch.cpp` sits in the same folder.
3. Rebuild with `scripts/build_app.sh`.

**The SDK version must be the same as or older than the installed Desktop Video
driver.** This Mac currently has Desktop Video **12.4.1** installed. Either use
SDK 12.4.x, or update the driver first: `Blackmagic_Desktop_Video_14.1.dmg` is
already in ~/Downloads, so install it and use SDK 14.1. Then pick the device and
video mode in the output's settings. Each DeckLink connector (sub-device) can
drive one output at a time.

## Syphon

Syphon is **built in**. Its BSD-licensed source lives in `ThirdParty/Syphon`
and is compiled straight into the app. The prebuilt Syphon SDK release on
GitHub dates from 2019, is Intel-only, and has no Metal server, which is why it
isn't used. `ThirdParty/Syphon/README-BroadcastBrowser.md` lists the source
commit and the one change made to it (the Metal shader is compiled at runtime,
so no Xcode is needed).

## NDI®

NDI is loaded at runtime from an installed NDI runtime. NDI Tools, the NDI SDK
for Apple, or a copy of `libndi.dylib` all work. On this Mac it's found
automatically inside NDI Tools. To bundle a specific runtime, put
`libndi.dylib` from the NDI SDK in this folder.

NDI® is a registered trademark of Vizrt NDI AB.
