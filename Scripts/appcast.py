#!/usr/bin/env python3
"""Adds a release to ImageSmith's Sparkle appcast, newest first. Used by Scripts/release.sh.

  appcast.py appcast.xml --version 1.0.1 --build 57 --min-os 14.0 --url URL \
      --signature 'sparkle:edSignature="…" length="…"' --notes URL
  appcast.py appcast.xml --check-build 57    # exit 1 unless 57 beats every build

Sparkle offers an update only when its build number is higher than the installed
one, so a lower or repeated build (e.g. after a history rewrite) is refused.
"""
import argparse
import email.utils
import os
import re
import sys
from xml.sax.saxutils import escape

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>ImageSmith</title>
    <link>https://github.com/newtro/ImageSmith</link>
    <description>ImageSmith updates</description>
    <language>en</language>
"""
FOOTER = """  </channel>
</rss>
"""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("appcast")
    p.add_argument("--check-build")
    p.add_argument("--version")
    p.add_argument("--build")
    p.add_argument("--min-os")
    p.add_argument("--url")
    p.add_argument("--signature")
    p.add_argument("--notes")
    a = p.parse_args()

    text = open(a.appcast, encoding="utf-8").read() if os.path.exists(a.appcast) else ""
    builds = [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", text)]
    newest = max(builds, default=0)

    if a.check_build:
        if int(a.check_build) <= newest:
            sys.exit(f"Build {a.check_build} isn't higher than build {newest} already in {a.appcast}; "
                     "installed copies would never be offered it.")
        return

    missing = [n for n in ("version", "build", "min_os", "url", "signature", "notes") if not getattr(a, n)]
    if missing:
        p.error("missing " + ", ".join("--" + n.replace("_", "-") for n in missing))
    if int(a.build) <= newest:
        sys.exit(f"Build {a.build} isn't higher than build {newest} already in {a.appcast}")

    sig = re.search(r'sparkle:edSignature="([^"]+)"', a.signature)
    length = re.search(r'length="(\d+)"', a.signature)
    if not sig or not length:
        sys.exit(f"Unexpected sign_update output: {a.signature!r}")

    found = re.findall(r"[ \t]*<item>.*?</item>[ \t]*\n?", text, flags=re.S)
    if len(found) != text.count("<item>"):
        sys.exit(f"Couldn't read every <item> in {a.appcast}; fix it by hand first.")
    items = "".join("    " + i.strip() + "\n" for i in found)

    item = f"""    <item>
      <title>Version {escape(a.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(a.min_os)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(a.notes)}</sparkle:releaseNotesLink>
      <enclosure url="{escape(a.url)}" type="application/octet-stream" sparkle:edSignature="{sig.group(1)}" length="{length.group(1)}"/>
    </item>
"""
    with open(a.appcast, "w", encoding="utf-8") as f:
        f.write(HEADER + item + items + FOOTER)
    print(f"Added {a.version} ({a.build}) to {a.appcast}")


if __name__ == "__main__":
    main()
