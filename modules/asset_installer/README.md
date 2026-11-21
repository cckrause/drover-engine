# Asset installer

Independent Zig module for the macOS game's first launch. It imports no engine
code. Storage, ISO parsing, SHA-256, ZIP/deflate extraction, and HTTPS use Zig's
standard library. The macOS adapter is also Zig: it calls system AppKit/WebKit
through their native ABI. There are no Objective-C source files, extra package
requirements, external extractor programs, or Windows executables to run.
The embedded HTML contains only presentation and the reference's disc animation;
installation state, filesystem access, networking, and validation stay in Zig.

The caller supplies its existing native window and an event pump. `macos.run`
adds an installer view to that window, then removes it before returning a
`Kind`. It creates no installer window and does not start or control the engine.
`Store.dataPath` returns a normal `OUTLAWS.LAB` path for the caller to load.

- No assets: show the small drop area, Choose files, and Download Outlaws Demo.
- Demo installed: show the same screen with Play Demo on every new app launch.
  Download completion stays on this screen until Play Demo is selected.
- Both retail discs installed: return retail immediately on subsequent launches.
  The full installation and demo are separate; installing a demo cannot replace
  retail files. Closing the window returns cancellation.

The game's integration uses
`~/Library/Application Support/o-reverse/Outlaws/assets/`, outside the bundle.
Existing explicit game paths, development assets, bundled assets, and headless
asset diagnostics continue to work. `outlaws --installer` enters this startup
flow deliberately even when development assets are present; a complete retail
installation still bypasses the screen.

Supported retail inputs are ISO 9660 images with 2048-byte sectors, and raw
Mode 1 BIN/MDF images with 2352-byte sectors. Disc identities and archive hashes
are checked against the supplied original English retail discs (`OUTLAWS_1`
and `OUTLAWS_2`). Both discs are required, in either order and across launches.
These image imports install data, including campaign movies. Plain ISO images
contain no CD music; MDS/CUE audio extraction is outside this module's current
scope. UDF-only, Mode 2, interleaved, extended-attribute, multi-volume, compressed,
and multi-extent images and unsupported retail asset revisions are rejected.

The original demo is downloaded on demand from
https://archive.org/download/outdemo_v2/outdemo_v2.exe (the
https://archive.org/details/outdemo_v2 item). Expected length: 14,186,356 bytes;
SHA-256: `501f37aa475b6c27c87ce04e30b5207f91b81603cb376aaa9ffde1647a40e7b3`.
Selecting that same `.exe` locally also works. Its authenticated ZIP members
are read in memory, with CRC checks and explicit size limits. Only its original
LAB and two SAN movies are installed. Hard links expose the combined demo LAB
under the seven archive filenames the retail engine uses; no resources change.

Imports run on a worker while the caller pumps its window. An exclusive file
lock serializes imports. Complete files, a required-file manifest, and SHA-256
checks precede publication; interrupted staging is never treated as installed.
Installation failures remain on the screen and allow another attempt.

From the engine checkout:

```sh
zig build test-installer          # original demo, both discs, corruption/retry
zig build test-installer-download # real Internet Archive download and install
zig build test-installer-native   # real macOS view, file import, Play, relaunch
zig test modules/asset_installer/src/root.zig # std-only standalone tests
```

The module also has its own `build.zig`; tests requiring original media skip
when fixtures are absent. Native tests require macOS and test the actual
rendered DOM bounds at 640×480 as well as reusing/removing the caller's view.
No proprietary assets are distributed with the module.
