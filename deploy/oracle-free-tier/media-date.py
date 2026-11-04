#!/usr/bin/env python3
"""Stamp each media file's mtime with the date the camera recorded.

gotohp dates an upload from os.Stat().ModTime() (core/upload.go), and
--date-from-filename only helps when the name carries a date - Watermelon writes
IMG_1234, so it does nothing there. SFTP does not carry the capture time across
reliably either, so a node arrives stamped with the transfer time and every
photo would land in Google Photos under "today".

This reads the date stored inside the file - EXIF DateTimeOriginal for images,
the movie header for videos, with a plain EXIF-shaped date string as a fallback
for containers that are not parsed here (HEIC, RAW) - and sets mtime to it.
Files with no usable date keep the mtime they arrived with.

Paths arrive NUL separated on stdin. sync.sh passes only files that have not
been uploaded yet, so repeat runs cost little and write nothing.

    find "$SRC_DIR" -type f -print0 | python3 media-date.py
"""

import os
import re
import struct
import sys
import time

# EXIF dates are naive local time; this is the range worth trusting.
EARLIEST_YEAR = 1990
LATEST_YEAR = 1  # relative to now

# "2019:07:09 18:20:27", also seen with a T separator. timedatectl offsets are
# handled by the container-specific readers, not here.
DATE_TEXT = re.compile(
    rb"((?:19|20)\d{2}):([01]\d):([0-3]\d)[ T]([0-2]\d):([0-5]\d):([0-5]\d)"
)

HEAD_BYTES = 1024 * 1024
TAIL_BYTES = 4 * 1024 * 1024

# Seconds between the 1904-01-01 QuickTime epoch and the Unix epoch.
QUICKTIME_EPOCH = 2082844800

TAG_DATE_TIME_ORIGINAL = 0x9003
TAG_DATE_TIME_DIGITIZED = 0x9004
TAG_DATE_TIME = 0x0132
TAG_EXIF_IFD = 0x8769


def local_stamp(year, month, day, hour, minute, second):
    """Epoch seconds for a naive wall-clock time, or None if implausible."""
    now_year = time.gmtime().tm_year
    if year < EARLIEST_YEAR or year > now_year + LATEST_YEAR:
        return None
    try:
        return int(time.mktime((year, month, day, hour, minute, second, 0, 1, -1)))
    except (OverflowError, ValueError):
        return None


def parse_date_text(text):
    match = DATE_TEXT.fullmatch(text)
    if not match:
        return None
    parts = [int(group) for group in match.groups()]
    return local_stamp(*parts)


def tiff_dates(buf, base):
    """Dates from a TIFF header at `base` (JPEG APP1, PNG eXIf, bare TIFF)."""
    if base + 8 > len(buf):
        return {}
    order = buf[base:base + 2]
    if order == b"II":
        endian = "<"
    elif order == b"MM":
        endian = ">"
    else:
        return {}

    try:
        magic, ifd0 = struct.unpack_from(endian + "HI", buf, base + 2)
    except struct.error:
        return {}
    if magic != 42:
        return {}

    found = {}
    visited = set()
    pending = [ifd0]

    while pending:
        offset = pending.pop()
        if offset < 8 or offset in visited or len(visited) > 4:
            continue
        visited.add(offset)
        try:
            count = struct.unpack_from(endian + "H", buf, base + offset)[0]
        except struct.error:
            continue
        if base + offset + 2 + count * 12 > len(buf):
            continue

        for index in range(count):
            entry = base + offset + 2 + index * 12
            try:
                tag, kind, size = struct.unpack_from(endian + "HHI", buf, entry)
            except struct.error:
                break

            if tag == TAG_EXIF_IFD and kind in (4, 13):
                try:
                    pending.append(struct.unpack_from(endian + "I", buf, entry + 8)[0])
                except struct.error:
                    pass
                continue

            if tag not in (TAG_DATE_TIME_ORIGINAL, TAG_DATE_TIME_DIGITIZED, TAG_DATE_TIME):
                continue
            if kind != 2 or not 0 < size <= 32:
                continue

            if size <= 4:
                raw = buf[entry + 8:entry + 8 + size]
            else:
                try:
                    value_offset = struct.unpack_from(endian + "I", buf, entry + 8)[0]
                except struct.error:
                    continue
                raw = buf[base + value_offset:base + value_offset + size] or b""

            stamp = parse_date_text(raw.split(b"\0")[0].strip())
            if stamp is not None and tag not in found:
                found[tag] = stamp

    return found


def best(dates):
    for tag in (TAG_DATE_TIME_ORIGINAL, TAG_DATE_TIME_DIGITIZED, TAG_DATE_TIME):
        if tag in dates:
            return dates[tag]
    return None


def image_date(data):
    """EXIF capture time from a JPEG, PNG, TIFF or similar byte prefix."""
    if data[:2] == b"\xff\xd8":
        pos = 2
        while pos + 4 <= len(data):
            if data[pos] != 0xFF:
                return None
            marker = data[pos + 1]
            if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
                pos += 2
                continue
            if marker == 0xDA:  # start of scan: metadata is over
                return None
            (length,) = struct.unpack_from(">H", data, pos + 2)
            if marker == 0xE1 and data[pos + 4:pos + 10] == b"Exif\0\0":
                stamp = best(tiff_dates(data, pos + 10))
                if stamp is not None:
                    return stamp
            if length < 2:
                return None
            pos += 2 + length
        return None

    if data[:8] == b"\x89PNG\r\n\x1a\n":
        pos = 8
        while pos + 8 <= len(data):
            (length,) = struct.unpack_from(">I", data, pos)
            kind = data[pos + 4:pos + 8]
            if kind == b"eXIf":
                stamp = best(tiff_dates(data, pos + 8))
                if stamp is not None:
                    return stamp
            if kind in (b"IDAT", b"IEND"):
                return None
            pos += 12 + length
        return None

    if data[:4] in (b"II*\0", b"MM\0*"):
        return best(tiff_dates(data, 0))

    return None


def movie_date(data):
    """Creation time from an ISO base media movie header (mp4, mov, 3gp)."""
    if not data:
        return None
    pos = data.find(b"mvhd")
    while pos != -1:
        if pos + 12 <= len(data):
            version = data[pos + 4]
            if version == 1 and pos + 16 <= len(data):
                (created,) = struct.unpack_from(">Q", data, pos + 8)
            else:
                (created,) = struct.unpack_from(">I", data, pos + 8)
            if created > QUICKTIME_EPOCH + 315532800:  # after 1980
                stamp = created - QUICKTIME_EPOCH
                if local_stamp(
                    *time.gmtime(stamp)[:6]
                ) is not None:
                    return stamp
        pos = data.find(b"mvhd", pos + 4)
    return None


def embedded_date_for(path):
    try:
        with open(path, "rb") as handle:
            size = os.fstat(handle.fileno()).st_size
            head = handle.read(HEAD_BYTES)
            tail = b""
            if size > HEAD_BYTES + TAIL_BYTES:
                handle.seek(size - TAIL_BYTES)
                tail = handle.read()
    except OSError:
        return None

    if head[4:8] == b"ftyp":
        stamp = movie_date(head) or movie_date(tail)
    else:
        stamp = image_date(head)
    if stamp is not None:
        return stamp

    # Fallback for containers this does not parse: HEIC, RAW, and anything else
    # that embeds an EXIF block as plain ASCII.
    match = DATE_TEXT.search(head)
    if match:
        return local_stamp(*[int(group) for group in match.groups()])
    return None


def main():
    seen = 0
    changed = 0

    for raw in sys.stdin.buffer.read().split(b"\0"):
        if not raw:
            continue
        path = raw.decode("utf-8", "surrogateescape")
        seen += 1

        stamp = embedded_date_for(path)
        if stamp is None:
            continue
        try:
            current = os.stat(path).st_mtime
            if int(current) == stamp:
                continue
            os.utime(path, (stamp, stamp))
            changed += 1
        except OSError:
            continue

    print(f"dated {changed} of {seen} file(s) from their own metadata", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
