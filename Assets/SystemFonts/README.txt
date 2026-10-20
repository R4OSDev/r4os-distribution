Stock bitmap fonts, revision 0.85.40
==================================
Terminal8/16 and all twelve R4Sans regular/bold sizes contain exactly 257
Unicode scalar glyphs: CP437 printable positions 20..7E and 80..FF (223),
the 32 distinct historical PC pictures (including the DEL-position house),
Euro U+20AC and replacement U+FFFD. No C0 or DEL scalar is a graphic glyph;
the separate R4STD PC-graphics mapping supplies their graphic Unicode values.
This is a bounded repertoire, not full Unicode coverage or text decoding.

Existing ASCII sources remain byte exact. The 162 supplementary glyphs use
120 pinned font8x8 glyphs and 42 R4OS-authored symbols. Original headers and
notices are in ThirdParty/font8x8; PROVENANCE.json records original hashes,
array-index assignments and the LSB-left to MSB-left bit reversal. Declared
array indices correct several repeated upstream Unicode comments.

Terminal cells keep exact 8-pixel width, full rows and 8/16-pixel height, so
line/block edges join without added spacing. R4Sans remains proportional UI
text with its existing line leading; line/block glyphs preserve the complete
square and have no extra horizontal gap or bold expansion. This does not
turn proportional UI text into a terminal grid.

Build/test through the Distribution owner on either host:
    ./Build.sh font-test
    Build.bat font-test
The shared PowerShell action builds all fourteen artifacts, directly runs
four generator, two writer and eight importer cases, and explicitly skips
only the optional local research case when no fixture directory is supplied.
Use -LegacyFontFixtures with a local directory containing the six historical
comparison FONs to run the ninth importer case too. These files are neither
downloaded nor distributed. Artifacts use Unicode GMAP records in R4F1.
The native decoder tests run through Kernel/Tools/Test-Fonts.ps1 after this
build and read the real generated assets. Fonts /TEXTTEST also verifies
native row output and three actual installed FNT imports in the guest.
For early headless AUTOEXEC use the Fonts Tests/TextConsumer FONTTEST.R4X
fixture with /TEXTTEST: it calls the identical app source without requiring
the ordinary hosted GUI launch. IMAGE_SCOPE=none keeps it out of products.
