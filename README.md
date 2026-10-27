# Grabby

A macOS app for the TerraTec Grabby USB video grabber: live preview, picture
controls, photos and movie recording with sound.

macOS has no driver for the Grabby's video, because it is not a standard
USB webcam (UVC) device. This app contains its own user-space driver,
built on libusb, so no kernel extension or system driver is needed.

## Features

- Live preview from the composite or S-Video input, PAL or NTSC (detected automatically)
- Brightness, contrast, saturation, hue and sharpness
- Deinterlacing: off, blend, or line doubling
- Photos (PNG, JPEG, HEIC) with ⌘T or the snapshot button on the Grabby, saved to `~/Pictures/Grabby`
- Movies (H.264, HEVC or ProRes 422 with AAC audio) with ⌘R, saved to `~/Movies/Grabby`
- Listening to the input through the Mac's speakers, plus an audio level meter
- The Grabby's LED lights up while video is streaming

## Building

Requirements: macOS 14 or later, Xcode command line tools, and `brew install libusb`.

```sh
scripts/build-app.sh          # builds build/Grabby.app (release)
open build/Grabby.app
```

When the app first starts, macOS asks for microphone access. Allow it so movies get
their sound from the Grabby's audio input.

For development, `swift run Grabby` also works. Microphone permission is then
granted to the terminal app instead.

### Hardware check

`grabby-probe` tests the driver without the app:

```sh
swift run grabby-probe 3 frame.yuv            # stream for 3 s, save the last frame
GRABBY_DEBUG=1 swift run grabby-probe 3       # with driver logging
ffmpeg -f rawvideo -pix_fmt yuyv422 -s 720x576 -i frame.yuv frame.png
```

`build/Grabby.app/Contents/MacOS/Grabby --smoke-test 3` starts the app, takes a photo,
records 3 seconds, prints the file paths and quits.

## How it works

| Part | Where |
|------|-------|
| EM2860 bridge, SAA7113 decoder and AC97 codec setup, isochronous streaming, field assembly | `Sources/CGrabby/grabby.c` |
| Deinterlacing | `Sources/CGrabby/frame.c` |
| Swift wrapper for the driver | `Sources/Grabby/Driver/GrabbyDriver.swift` |
| Frames to `CVPixelBuffer`, preview, photos and recording | `Sources/Grabby/Capture/` |
| Interface | `Sources/Grabby/UI/` |

The Grabby (USB ID `0ccd:0096`) has an Empia EM2860 USB bridge, a Philips SAA7113 video
decoder and a SigmaTel AC97 codec:

- **Video:** interface 0, alternate setting 7, three 1024-byte isochronous packets per
  microframe. The stream is packed YUYV 4:2:2, one field at a time, and the driver weaves
  the two fields into 720×576 (PAL) or 720×480 (NTSC) frames.
- **Audio:** a standard USB Audio Class interface, so CoreAudio handles it. The driver only
  routes the RCA audio input to the codec's ADC.

Register sequences follow the Linux `em28xx` and `saa7115` drivers.

Movies keep the original 720-sample lines and are tagged with the right pixel aspect
ratio (16:15 for PAL, 8:9 for NTSC), so players show them as 4:3. Photos are resampled
to square pixels.
