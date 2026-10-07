# swift-exif-writer

Writes the place a photograph was made into the file's EXIF, **without
decoding or re-encoding the picture**. The encoded picture is never read.
Only the few bytes of metadata that hold the position change. Where the
file's XMP packet states the position too, that copy is changed with it.

Swift, Foundation only. No ImageIO, so it builds on macOS, iOS and Linux.

```swift
import ExifWriter

let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
try ExifGPS.setPosition(bixby, inFileAt: url, as: .tiff)

try ExifGPS.position(inFileAt: url, as: .tiff)      // the position, or nil
try ExifGPS.setPosition(nil, inFileAt: url, as: .tiff)   // take it out

try ExifGPS.setPosition(bixby, inFileAt: other, as: .png)
try ExifGPS.setPosition(bixby, inFileAt: phone, as: .heic)
```

And, in a TIFF, the text its EXIF states: what made the picture, through
what lens, and when.

```swift
try ExifText.set([.model: "Nikon FE2", .dateTimeOriginal: "2019:07:04 22:30:00",
                  .offsetTimeOriginal: "+02:00"],
                 removing: [.make], inFileAt: url, as: .tiff)

try ExifText.text(of: .model, inFileAt: url, as: .tiff)   // "Nikon FE2", or nil
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
| PNG | Written and read |
| HEIC | Written and read, where the file already has EXIF |

The caller says which format a file is. Most cameras' raw files are TIFF
structures too, and nothing in their first bytes tells them from a TIFF, so
this does not guess. **Do not hand it a raw file as `.tiff`.**

## What it changes

The four tags that are the position: latitude, longitude, and the letter
that signs each. Altitude, the time of the fix, the direction the camera
faced and everything else in the GPS block are carried across as they were.

**And the same position in the XMP packet, where the packet states one.**
A file can say where it was made a second time, as `exif:GPSLatitude` and
`exif:GPSLongitude` in its XMP. Some say it only there: Lightroom Classic
exports a PNG with its position in the packet and no EXIF at all. Setting a
position changes the packet's copy to agree, and taking one out takes it
out of both.

**A packet that states no position is left as the bytes it was**, and no
packet is made for a file that has none. The one exception is a PNG's
packet with something after its closing line, which is cut off (below). That is what ExifTool does: EXIF
is where a position belongs, and a second copy is kept in step only where
somebody already put one.

Reading gives the EXIF's position, and the packet's where the EXIF has
none. To know which said it, or whether a file somebody else wrote says two
different places, ask for them apart:

```swift
let stated = try ExifGPS.positions(inFileAt: url, as: .png)
stated.exif    // what the EXIF's GPS block states
stated.xmp     // what the XMP packet states
```

## How

EXIF is a TIFF structure wherever it is kept: a TIFF file is one, a PNG
holds one in its `eXIf` chunk, and a HEIC holds one as an item. Nothing that is already in that structure
moves. It is full of offsets counted from its first byte, and some are in
places a general reader cannot find, so it is never rebuilt:

- A new GPS block is written at the end of the file, and the four bytes
  that point at the block are changed.
- Where the first directory has no pointer to a block, a copy of that
  directory with one added goes at the end too, and the four bytes in the
  header that point at the directory are changed.
- A block this library wrote is the last thing in the structure. Writing
  again cuts it off and writes the new one in the same place, so a second
  write does not grow the file.

The first write adds a few hundred bytes.

**A TIFF is edited where it stands.** The new block is written first and
the pointer to it last, so an interrupted write leaves the picture and the
rest of the metadata readable. If you need all or nothing, write into a
copy and move it into place.

**A PNG is written whole to a new file, which then takes its place.** Its
EXIF chunk grows, or a new one goes in before the picture's data, and every
other chunk is carried across as the bytes it was, but for the packet's
where the packet changes. A PNG that had no EXIF,
given a position and then relieved of it, is byte for byte the file it
started as. EXIF found after the picture's data is moved before it, where
the format asks for it and where ExifTool puts it.

**A HEIC is written whole to a new file too.** Its EXIF is an item in the
file's data box, and another box holds every item's offset from the start
of the file. So the EXIF is replaced where it lies, what follows it sits
further along, the data box is given its new length, and every offset that
pointed past the EXIF is moved by the difference. That is how ExifTool does
it. Every other item is carried across as the bytes it was. An AVIF is laid
out the same way and has not been tried.

### The XMP packet

The packet is not parsed into a tree and written out again, which would
change its quoting, its order and its white space. It is read as far as
finding where the position's text lies, and that text alone is replaced or
cut out.

- **The position is found** as an attribute of a top-level
  `rdf:Description` or as an element inside one, under whatever prefix the
  packet gives the EXIF namespace. Lightroom writes attributes, ExifTool
  and ImageIO write elements.
- **It is written as XMP spells a coordinate**, `36,22.283340N`: degrees,
  then minutes to a millionth, then the hemisphere. A value found as a bare
  number, which ImageIO can write, is written back in XMP's form, and a
  hemisphere held apart in `exif:GPSLatitudeRef` is made to agree.
- **In a PNG** the packet is the text of an `iTXt` chunk, which is rebuilt
  with its new length and checksum where it was.
- **In a HEIC** the packet is an item, replaced the way the EXIF item is.
- **In a TIFF** the packet is changed where it lies when it fits: a packet
  ends in white space for the purpose, and a shorter position leaves more
  of it. Where it does not fit, the packet is written again at the end of
  the file, with room for any position, and the eight bytes that say where
  it is and how long are changed. That happens once. The packet it replaces
  stays in the bytes, unreferenced.
- **The packet ends at its closing line**, `<?xpacket end=…?>`. When
  ImageIO copies a PNG and the packet comes out shorter, it keeps the
  chunk's length and leaves the end of the old packet after that line
  (measured on macOS 27.0.1: 201 bytes of one). Those bytes are text, tags
  the file stated before, and ExifTool reads them. They are not read here.
- **What follows a PNG's packet is cut off on any write**, whether or not
  the packet states a position, and with nil too. It is not the packet, and
  it can hold a position the file no longer states. White space alone is
  left. So a call that finds no position to change can still change a PNG,
  and says so by returning true.
- **`ExifGPS.cutWhatFollowsThePacket` does only that**, for an app that has
  just written a PNG through ImageIO and has no position to set. It gives
  the file no EXIF it did not have.

## Text

`ExifText` sets and takes out the text tags of a TIFF's first directory and
of the EXIF directory it points at: `Make`, `Model`, `Software`,
`DateTimeOriginal`, `DateTimeDigitized`, the three offsets from UTC,
`LensMake`, `LensModel` and a few more (`ExifTag`).

**Why.** The same copy of ImageIO's that leaves a TIFF's GPS block alone
does not write the rest of what it was handed either. Measured on macOS
27.0.1, on a TIFF stating nothing and one stating a different value for
each tag, with the call returning true both times:

| Tag | File states none | File states another value |
| --- | --- | --- |
| `Orientation`, `DateTimeOriginal` | written | replaced |
| `Model`, `DateTimeDigitized`, `LensModel` | written | old value kept |
| `OffsetTimeOriginal` | not written | removed |
| `Make`, asked to be taken out | | kept |

So a caller that copies a TIFF through ImageIO sets these right afterwards,
with the position.

**The list is closed.** A caller cannot name a tag by its number. The same
directories hold the tags that say where the picture's data is, and a
caller that could take any tag out could take those.

**How**, by the rules the position follows:

- A value no longer than the one it replaces is written where that one
  lies. A date is always the same length, so changing one changes those
  bytes and nothing else. Not where another tag keeps its value in the
  same bytes, which would change both.
- A longer value goes at the end, and the eight bytes of its entry that
  say how long it is and where are changed.
- A tag the directory did not have makes it one entry longer, so the
  directory is written again at the end and the four bytes that point at
  it are changed. A file with no EXIF directory gets one, which says its
  version and nothing else.
- A tag taken out makes the directory shorter where it stands.
- **A GPS block that was the last thing in the file still is.** It is
  moved along and what is new is written before it, so the next position
  still does not grow the file.

Text is written as UTF-8, which is what ExifTool and ImageIO write and
read.

## Limits

- **Text is written for a TIFF and not for a PNG or a HEIC**, which are
  refused. Their EXIF is the same structure inside a chunk or an item.
- **Text is written to the EXIF alone.** A packet can state the same thing
  a second time, as `tiff:Model` or `exif:DateTimeOriginal`, and for text
  the packet is not read and not changed. A file whose packet states it
  comes out saying two things unless whatever writes the packet keeps it in
  step. This is not what the library does for a position.
- **A new EXIF directory states its version and nothing else.** ExifTool
  starts one with `FlashpixVersion` and a `ColorSpace` of uncalibrated,
  and its validation asks for both. The second is a statement about the
  picture's colour that nobody made.

- **A packet that cannot be read is a reason to refuse the file**, because
  what it states is then not known, and writing the EXIF alone could leave
  the file saying two places. That covers a packet that is compressed,
  which a PNG and a HEIC allow and XMP asks writers not to do, one that is
  not UTF-8, one that is not XML, and a position held as something other
  than plain text. Nothing is changed.
- **A position in a nested structure or under another namespace is not the
  file's position** and is left alone. So is one an app keeps under a
  namespace of its own.
- **What lies after a TIFF's or a HEIC's packet is neither read nor
  changed.** ImageIO has been seen to leave such bytes in a PNG only, and
  only a PNG's are cut. ExifTool reads whole tags out of them, and warns
  that their namespaces are out of scope.
- **A PNG's packet in an old-style text chunk is not read.** Some tools
  have written XMP as a `tEXt` or `zTXt` "raw profile". Only the `iTXt`
  chunk the XMP specification names is.
- **Set a PNG's position after ImageIO has copied the file, not before.**
  `CGImageDestinationCopyImageSource` rewrites a PNG's EXIF. On macOS
  27.0.1, a copy made with metadata that said nothing of the position
  brought one out with its latitude and without its longitude, whoever had
  written it. A TIFF and a HEIC come through the same copy with their
  position intact.
- **A HEIC with no EXIF at all is refused.** Giving it some means adding an
  item, which this does not do yet. Every HEIC a camera or ImageIO writes
  has EXIF. A HEIC that holds a sequence of pictures is refused too.
- **BigTIFF is refused**, and so is a file that would pass 4 GB.
- **It is a writer, not a scrubber.** A block that was replaced and was not
  the last thing in the file stays in the bytes, unreferenced. So does a
  TIFF's packet that was moved. Do not use this to remove a location from a file
  you are about to publish.
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
  it wrote itself. Where a file's packet stated a position, ExifTool reads
  the EXIF's and the packet's apart and both are the one set.
- **The packet on its own**, on packets laid out as Lightroom, ExifTool and
  ImageIO each lay one out: set, the packet is the same packet built from
  the new values, byte for byte, and taken out, the same packet built from
  none.
- **Against ImageIO**, on macOS, on TIFFs, PNGs and HEICs ImageIO wrote: 8
  and 16 bits, compressed and not, a TIFF of more than one page, a PNG with
  no metadata at all. It reads the position, the same decoded picture and
  the same properties. And on a TIFF, a PNG and a HEIC whose packet ImageIO
  wrote with the position in it: after each write ImageIO still reads what
  else the packet says, moved or not.
- **A HEIC's layouts**, on boxes built by hand: EXIF before the picture and
  after it, the item list before the data and after it, each version of
  the box that holds the offsets, offsets from a base, eight-byte offsets,
  a 64-bit data box.

**No HEIC straight from a phone has been tried yet.** The HEICs here were
written by ImageIO: two small ones kept beside the tests, and a 24 megapixel
one converted from a camera's JPEG.

CI runs all of it on macOS and the first two on Linux, and fails if
ExifTool is missing.

- **The text**, the same three ways: on hand-built TIFFs in both byte
  orders, where only the bytes that should change do; against ExifTool
  both ways round, with every other tag, the position and the digest of
  the picture as they were; and against ImageIO, on TIFFs it wrote, of 8
  and 16 bits, compressed, and of two pages. One test is the use this was
  written for: ImageIO's copy is handed a camera, a lens and a time, the
  text and the position are set in the file it wrote, and ImageIO reads
  every one, the same picture, and the packet the copy wrote.

### On your own photographs

A repository cannot hold your photographs, so there is a test that takes
them from you:

```sh
EXIF_WRITER_REAL_FILES=/path/to/a/folder swift test --filter RealFileTests
```

Each file is copied to the temporary directory and only the copy is
touched. Needs ExifTool.

The text tags have a test of the same kind, for the TIFFs in the folder:

```sh
EXIF_WRITER_REAL_FILES=/path/to/a/folder swift test --filter RealFileTests/testTextOnTIFFsOfYourOwn
```

To learn only which files would be refused, and why, there is a quicker
one that writes nothing and needs no ExifTool:

```sh
EXIF_WRITER_REAL_FILES=/path/to/a/folder swift test --filter RealFileTests/testWhichWouldBeRefused
```

## Installing

```swift
.package(url: "https://github.com/misterbisson/swift-exif-writer", from: "0.1.0")
```

## Licence

MIT.
