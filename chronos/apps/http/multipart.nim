#
#           Chronos HTTP/S multipart/form
#      encoding and decoding helper procedures
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[monotimes, strutils]
import chronos, stew/results
import httptable, httpcommon
export httptable, httpcommon

type
  MultiPartSource {.pure.} = enum
    Stream, Buffer

  MultiPartReader* = object
    case kind: MultiPartSource
    of MultiPartSource.Stream:
      stream: AsyncStreamReader
      last: BoundedAsyncStreamReader
    of MultiPartSource.Buffer:
      discard
    buffer: seq[byte]
    offset: int
    boundary: seq[byte]

  MultiPartReaderRef* = ref MultiPartReader

  MultiPart* = object
    headers: HttpTable
    stream: BoundedAsyncStreamReader
    offset: int
    size: int

  MultipartError* = object of HttpError
  MultipartEOMError* = object of MultipartError
  MultiPartIncorrectError* = object of MultipartError
  MultiPartIncompleteError* = object of MultipartError

  BChar* = byte | char

proc startsWith*(s, prefix: openarray[byte]): bool =
  var i = 0
  while true:
    if i >= len(prefix): return true
    if i >= len(s) or s[i] != prefix[i]: return false
    inc(i)

proc parseUntil*(s, until: openarray[byte]): int =
  var i = 0
  while i < len(s):
    if len(until) > 0 and s[i] == until[0]:
      var u = 1
      while i + u < len(s) and u < len(until) and s[i + u] == until[u]:
        inc u
      if u >= len(until): return i
    inc(i)
  -1

proc init*[A: BChar, B: BChar](mpt: typedesc[MultiPartReader],
                               buffer: openarray[A],
                               boundary: openarray[B]): MultiPartReader =
  # Boundary should not be empty.
  doAssert(len(boundary) > 0)
  # Our internal boundary has format `<CR><LF><-><-><boundary>`, so we can reuse
  # different parts of this sequence for processing.
  var fboundary = newSeq[byte](len(boundary) + 4)
  fboundary[0] = 0x0D'u8
  fboundary[1] = 0x0A'u8
  fboundary[2] = byte('-')
  fboundary[3] = byte('-')
  copyMem(addr fboundary[4], unsafeAddr boundary[0], len(boundary))
  # Make copy of buffer, because all the returned parts depending on it.
  var buf = newSeq[byte](len(buffer))
  if len(buf) > 0:
    copyMem(addr buf[0], unsafeAddr buffer[0], len(buffer))
  MultiPartReader(kind: MultiPartSource.Buffer,
                  buffer: buf, offset: 0, boundary: fboundary)

proc init*[B: BChar](mpt: typedesc[MultiPartReader],
                     stream: AsyncStreamReader,
                     boundary: openarray[B],
                     partHeadersMaxSize = 4096): MultiPartReader =
  # Boundary should not be empty.
  doAssert(len(boundary) > 0)
  # Our internal boundary has format `<CR><LF><-><-><boundary>`, so we can reuse
  # different parts of this sequence for processing.
  var fboundary = newSeq[byte](len(boundary) + 4)
  fboundary[0] = 0x0D'u8
  fboundary[1] = 0x0A'u8
  fboundary[2] = byte('-')
  fboundary[3] = byte('-')
  copyMem(addr fboundary[4], unsafeAddr boundary[0], len(boundary))
  MultiPartReader(kind: MultiPartSource.Stream,
                  stream: stream, offset: 0, boundary: fboundary,
                  buffer: newSeq[byte](partHeadersMaxSize))

proc readPart*(mpr: MultiPartReaderRef): Future[MultiPart] {.async.} =
  doAssert(mpr.kind == MultiPartSource.Stream)
  # According to RFC1521 says that a boundary "must be no longer than 70
  # characters, not counting the two leading hyphens.
  if mpr.firstTime:
    # Read and verify initial <-><-><boundary><CR><LF>
    mpr.firstTime = false
    await mpr.stream.readExactly(addr mpr.buffer[0], len(mpr.boundary) - 2)
    if startsWith(mpr.buffer.toOpenArray(0, len(mpr.boundary) - 5),
                  mpr.boundary.toOpenArray(2, len(mpr.boundary) - 1)):
      if buffer[0] == byte('-') and buffer[1] == byte("-"):
        raise newException(MultiPartEOMError, "Unexpected EOM encountered")
      if buffer[0] != 0x0D'u8 or buffer[1] != 0x0A'u8:
        raise newException(MultiPartIncorrectError,
                           "Unexpected boundary suffix")
    else:
      raise newException(MultiPartIncorrectError,
                         "Unexpected boundary encountered")

  # Reading part's headers
  let res = await mpr.stream.readUntil(addr mpr.buffer[0], len(mpr.buffer),
                                       HeadersMark)
  var headersList = parseHeaders(mpr.buffer.toOpenArray(0, res - 1))
  if headersList.failed():
    raise newException(MultiPartIncorrectError, "Incorrect part headers found")

  var part = MultiPart()

    await mpr.stream.readExactly(addr buffer[0], len(mpr.boundary) - 4)
    if startsWith(buffer.toOpenArray(0, len(mpr.boundary) - 5),
                  mpr.boundary.toOpenArray(2, len(mpr.boundary) - 1)):
      await mpr.stream.readExactly(addr buffer[0], 2)
      if buffer[0] == byte('-') and buffer[1] == byte("-"):
        raise newException(MultiPartEOMError, "")
      if buffer[0] == 0x0D'u8 and buffer[1] == 0x0A'u8:

  except:
    discard
  # if mpr.offset >= len(mpr.buffer):
  #   raise newException(MultiPartEOMError, "End of multipart form encountered")

proc getStream*(mp: MultiPart): AsyncStreamReader =
  mp.stream

proc getBody*(mp: MultiPart): Future[seq[byte]] {.async.} =
  try:
    let res = await mp.stream.read()
    return res
  except AsyncStreamError:
    raise newException(HttpCriticalError, "Could not read multipart body")

proc consumeBody*(mp: MultiPart) {.async.} =
  try:
    await mp.stream.consume()
  except AsyncStreamError:
    raise newException(HttpCriticalError, "Could not consume multipart body")

proc getPart*(mpr: var MultiPartReader): Result[MultiPart, string] =
  doAssert(mpr.kind == MultiPartSource.Buffer)
  if mpr.offset >= len(mpr.buffer):
    return err("End of multipart form encountered")

  if startsWith(mpr.buffer.toOpenArray(mpr.offset, len(mpr.buffer) - 1),
                mpr.boundary.toOpenArray(2, len(mpr.boundary) - 1)):
    # Buffer must start at <-><-><boundary>
    mpr.offset += (len(mpr.boundary) - 2)

    # After boundary there should be at least 2 symbols <-><-> or <CR><LF>.
    if len(mpr.buffer) <= mpr.offset + 1:
      return err("Incomplete multipart form")

    if mpr.buffer[mpr.offset] == byte('-') and
       mpr.buffer[mpr.offset + 1] == byte('-'):
      # If we have <-><-><boundary><-><-> it means we have found last boundary
      # of multipart message.
      mpr.offset += 2
      return err("End of multipart form encountered")

    if mpr.buffer[mpr.offset] == 0x0D'u8 and
       mpr.buffer[mpr.offset + 1] == 0x0A'u8:
      # If we have <-><-><boundary><CR><LF> it means that we have found another
      # part of multipart message.
      mpr.offset += 2
      # Multipart form must always have at least single Content-Disposition
      # header, so we searching position where all the headers should be
      # finished <CR><LF><CR><LF>.
      let pos1 = parseUntil(
        mpr.buffer.toOpenArray(mpr.offset, len(mpr.buffer) - 1),
        [0x0D'u8, 0x0A'u8, 0x0D'u8, 0x0A'u8]
      )

      if pos1 < 0:
        return err("Incomplete multipart form")

      # parseUntil returns 0-based position without `until` sequence.
      let start = mpr.offset + pos1 + 4

      # Multipart headers position
      let hstart = mpr.offset
      let hfinish = mpr.offset + pos1 + 4 - 1

      let headersList = parseHeaders(mpr.buffer.toOpenArray(hstart, hfinish),
                                     false)
      if headersList.failed():
        return err("Incorrect or incomplete multipart headers received")

      # Searching for value's boundary <CR><LF><-><-><boundary>.
      let pos2 = parseUntil(
        mpr.buffer.toOpenArray(start, len(mpr.buffer) - 1),
        mpr.boundary.toOpenArray(0, len(mpr.boundary) - 1)
      )

      if pos2 < 0:
        return err("Incomplete multipart form")

      # We set reader's offset to the place right after <CR><LF>
      mpr.offset = start + pos2 + 2

      var part = MultiPart(offset: start, size: pos2, headers: HttpTable.init())
      for k, v in headersList.headers(mpr.buffer.toOpenArray(hstart, hfinish)):
        part.headers.add(k, v)
      ok(part)
    else:
      err("Incorrect multipart form")
  else:
    err("Incorrect multipart form")

template `-`(x: uint32): uint32 =
  (0xFFFF_FFFF'u32 - x) + 1'u32

template LT(x, y: uint32): uint32 =
  let z = x - y
  (z xor ((y xor x) and (y xor z))) shr 31

proc boundaryValue(c: char): bool =
  let a0 = uint32(c) - 0x27'u32
  let a1 = uint32(c) - 0x2B'u32
  let a2 = uint32(c) - 0x3A'u32
  let a3 = uint32(c) - 0x3D'u32
  let a4 = uint32(c) - 0x3F'u32
  let a5 = uint32(c) - 0x41'u32
  let a6 = uint32(c) - 0x5F
  let a7 = uint32(c) - 0x61'u32
  let r = ((a0 + 1'u32) and -LT(a0, 3)) or
          ((a1 + 1'u32) and -LT(a1, 15)) or
          ((a2 + 1'u32) and -LT(a2, 1)) or
          ((a3 + 1'u32) and -LT(a3, 1)) or
          ((a4 + 1'u32) and -LT(a4, 1)) or
          ((a5 + 1'u32) and -LT(a5, 26)) or
          ((a6 + 1'u32) and -LT(a6, 1)) or
          ((a7 + 1'u32) and -LT(a7, 26))
  (int(r) - 1) > 0

proc boundaryValue2(c: char): bool =
  c in {'a'..'z', 'A' .. 'Z', '0' .. '9',
        '\'' .. ')', '+' .. '/', ':', '=', '?', '_'}

func getMultipartBoundary*(contentType: string): Result[string, string] =
  let mparts = contentType.split(";")
  if strip(mparts[0]).toLowerAscii() != "multipart/form-data":
    return err("Content-Type is not multipart")
  if len(mparts) < 2:
    return err("Content-Type missing boundary value")
  let stripped = strip(mparts[1])
  if not(stripped.toLowerAscii().startsWith("boundary")):
    return err("Incorrect Content-Type boundary format")
  let bparts = stripped.split("=")
  if len(bparts) < 2:
    err("Missing Content-Type boundary")
  else:
    ok(strip(bparts[1]))

func getContentType*(contentHeader: seq[string]): Result[string, string] =
  if len(contentHeader) > 1:
    return err("Multiple Content-Header values found")
  let mparts = contentHeader[0].split(";")
  ok(strip(mparts[0]).toLowerAscii())

when isMainModule:
  var buf = "--------------------------5e7d0dd0ed6eb849\r\nContent-Disposition: form-data; name=\"key1\"\r\n\r\nvalue1\r\n--------------------------5e7d0dd0ed6eb849\r\nContent-Disposition: form-data; name=\"key2\"\r\n\r\nvalue2\r\n--------------------------5e7d0dd0ed6eb849--"
  var reader = MultiPartReader.init(buf, "------------------------5e7d0dd0ed6eb849")
  echo getPart(reader)
  echo "===="
  echo getPart(reader)
  echo "===="
  echo getPart(reader)