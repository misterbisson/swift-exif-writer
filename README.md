# swift-exif-writer

Writes the place a photograph was made into the file's EXIF, **without
decoding or re-encoding the picture**. The encoded picture is never read.
Only the few bytes of metadata that hold the position change.

Swift, Foundation only. No ImageIO, so it builds on macOS, iOS and Linux.

```swift
import ExifWriter

let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
try ExifGPS.setPosition(bixby, inFileAt: url, as: .tiff)

try ExifGPS.position(inFileAt: url, as: .tiff)      // the position, or nil
try ExifGPS.setPosition(nil, inFileAt: url, as: .tiff)   // take it out
```

## Why

Apple's `CGImageDestinationCopyImageSource` rewrites a file's metadata
without re-encoding it, and for a JPEG that includes the GPS block. For a
TIFF and a HEIC it reports success and leaves the block as it was (measured
on macOS 27.0.1). The other route ImageIO offers is to decode the picture
and encode it again. That is lossy for a HEIC, and for a TIFF it means
everything else in the file has to be carried across on purpose.

[ExifTool](https://exiftool.org) does this properly, and is a Perl program,
which an app cannot always ship. This is the one part of that job, in
Swift, checked against ExifTool.

## Formats

| Format | Status |
| --- | --- |
| TIFF | Written and read |
| PNG | Planned |
| HEIC | Planned |

The caller says which format a file is. Most cameras' raw files are TIFF
structures too, and nothing in their first bytes tells them from a TIFF, so
this does not guess. **Do not hand it a raw file as `.tiff`.**

## What it changes

The four tags that are the position: latitude, longitude, and the letter
that signs each. Altitude, the time of the fix, the direction the camera
faced and everything else in the GPS block are carried across as they were.

## How

Nothing that is already in the file moves. A TIFF structure is full of
offsets counted from its first byte, and some are in places a general
reader cannot find, so the structure is never rebuilt:

- A new GPS block is written at the end of the file, and the four bytes
  that point at the block are changed.
- Where the first directory has no pointer to a block, a copy of that
  directory with one added goes at the end too, and the four bytes in the
  header that point at the directory are changed.
- A block this library wrote is the last thing in the file. Writing again
  cuts it off and writes the new one in the same place, so a second write
  does not grow the file.

The first write adds a few hundred bytes. The file is edited where it
stands: the new block is written first and the pointer to it last, so an
interrupted write leaves the picture and the rest of the metadata readable.
If you need all or nothing, write into a copy and move it into place.

## Limits

- **BigTIFF is refused**, and so is a file that would pass 4 GB.
- **It is a writer, not a scrubber.** A block that was replaced and was not
  the last thing in the file stays in the bytes, unreferenced. Do not use
  this to remove a location from a file you are about to publish.
- A position is kept to a millionth of a second of arc. Apple's ImageIO
  gives any file's position back to a ten-thousandth of a minute, about
  18 cm, whoever wrote it.

## How it is checked

- **By hand-built files** in both byte orders, where the tests know where
  every byte is: only the pointer bytes change in what was already there.
- **Against ExifTool**, both ways round. ExifTool reads the position this
  wrote and reports every other tag, and a digest of the picture's data, as
  they were. This reads what ExifTool wrote. ExifTool's validation finds
  nothing wrong with a file from here that it does not find wrong with one
  it wrote itself.
- **Against ImageIO**, on macOS, on TIFFs ImageIO wrote: 8 and 16 bits,
  compressed and not, more than one page. It reads the position, the same
  decoded picture and the same properties, and can copy the file afterwards
  without losing the position.

CI runs all of it on macOS and the first two on Linux, and fails if
ExifTool is missing.

### On your own photographs

A repository cannot hold your photographs, so there is a test that takes
them from you:

```sh
EXIF_WRITER_REAL_FILES=/path/to/a/folder swift test --filter RealFileTests
```

Each file is copied to the temporary directory and only the copy is
touched. Needs ExifTool.

## Installing

```swift
.package(url: "https://github.com/misterbisson/swift-exif-writer", from: "0.1.0")
```

## Licence

MIT.
