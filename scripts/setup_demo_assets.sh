#!/usr/bin/env bash
# setup_demo_assets.sh
# Downloads real CC-licensed audio tracks and artwork for Kenopsia's demo mode.
# Run once before building. Safe to re-run (skips existing files).
#
# Audio source: Internet Archive (archive.org)
# Artwork source: archive.org thumbnail service + iTunes API + TheAudioDB
#
# Attribution (CC BY 4.0 unless noted):
#   Chris Zabriskie  - https://chriszabriskie.com
#   Lee Rosevere     - https://leerosevere.bandcamp.com
#   Kai Engel        - http://freemusicarchive.org/music/Kai_Engel
#   Kevin MacLeod    - https://incompetech.com
#   Jahzzar          - https://jahzzar.bandcamp.com  (CC BY-SA 3.0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ASSETS_DIR="$ROOT_DIR/Kenopsia/DemoAssets"
AUDIO_DIR="$ASSETS_DIR/Audio"
ARTWORK_DIR="$ASSETS_DIR/Artwork"

mkdir -p "$AUDIO_DIR" "$ARTWORK_DIR"

dl() {
    local url="$1" dst="$2"
    if [[ -f "$dst" ]] && [[ -s "$dst" ]]; then
        echo "  skip  $(basename "$dst")"
        return 0
    fi
    echo "  fetch $(basename "$dst")"
    if ! curl -sL --retry 3 --max-time 60 -o "$dst" "$url"; then
        echo "  FAIL  $(basename "$dst") <- $url"
        rm -f "$dst"
        return 1
    fi
    if [[ ! -s "$dst" ]]; then
        echo "  EMPTY $(basename "$dst")"
        rm -f "$dst"
        return 1
    fi
}

ARCHIVE="https://archive.org/download"

echo "=== Audio: Chris Zabriskie – Cylinders (Electronic, CC BY 4.0) ==="
dl "$ARCHIVE/Cylinders-15736/Chris_Zabriskie_-_01_-_Cylinder_One.mp3"        "$AUDIO_DIR/cylinders_01.mp3"
dl "$ARCHIVE/Cylinders-15736/Chris_Zabriskie_-_02_-_Cylinder_Two.mp3"        "$AUDIO_DIR/cylinders_02.mp3"
dl "$ARCHIVE/Cylinders-15736/Chris_Zabriskie_-_03_-_Cylinder_Three.mp3"      "$AUDIO_DIR/cylinders_03.mp3"
dl "$ARCHIVE/Cylinders-15736/Chris_Zabriskie_-_04_-_Cylinder_Four.mp3"       "$AUDIO_DIR/cylinders_04.mp3"
dl "$ARCHIVE/Cylinders-15736/Chris_Zabriskie_-_05_-_Cylinder_Five.mp3"       "$AUDIO_DIR/cylinders_05.mp3"

echo "=== Audio: Lee Rosevere – Music Inspired by MiNRS (Cinematic, CC BY 4.0) ==="
dl "$ARCHIVE/Music_Inspired_by_MiNRS-22282/Lee_Rosevere_-_01_-_Perses.mp3"           "$AUDIO_DIR/minrs_01.mp3"
dl "$ARCHIVE/Music_Inspired_by_MiNRS-22282/Lee_Rosevere_-_02_-_The_Great_Mission.mp3" "$AUDIO_DIR/minrs_02.mp3"
dl "$ARCHIVE/Music_Inspired_by_MiNRS-22282/Lee_Rosevere_-_03_-_Blackout.mp3"         "$AUDIO_DIR/minrs_03.mp3"
dl "$ARCHIVE/Music_Inspired_by_MiNRS-22282/Lee_Rosevere_-_04_-_In_the_Mines.mp3"     "$AUDIO_DIR/minrs_04.mp3"
dl "$ARCHIVE/Music_Inspired_by_MiNRS-22282/Lee_Rosevere_-_05_-_Landers.mp3"          "$AUDIO_DIR/minrs_05.mp3"

echo "=== Audio: Kai Engel – Idea (Ambient/Piano, CC BY 4.0) ==="
dl "$ARCHIVE/kai-engel/Kai_Engel_-_01_-_Idea.mp3"                                      "$AUDIO_DIR/idea_01.mp3"
dl "$ARCHIVE/kai-engel/Kai_Engel_-_02_-_Endless_Story_About_Sun_and_Moon.mp3"          "$AUDIO_DIR/idea_02.mp3"
dl "$ARCHIVE/kai-engel/Kai_Engel_-_03_-_After_Midnight.mp3"                            "$AUDIO_DIR/idea_03.mp3"
dl "$ARCHIVE/kai-engel/Kai_Engel_-_04_-_Behind_Your_Window.mp3"                        "$AUDIO_DIR/idea_04.mp3"
dl "$ARCHIVE/kai-engel/Kai_Engel_-_05_-_Touch_the_Darkness.mp3"                        "$AUDIO_DIR/idea_05.mp3"

echo "=== Audio: Kevin MacLeod – Vicious (Electronic/Action, CC BY 4.0) ==="
VICIOUS="$ARCHIVE/Kevin-MacLeod_Vicious_2016_FullAlbum/Vicious"
dl "$VICIOUS/Kevin%20MacLeod%20-%2001%20-%20Pyro%20Flow.mp3"       "$AUDIO_DIR/vicious_01.mp3"
dl "$VICIOUS/Kevin%20MacLeod%20-%2002%20-%20Vicious.mp3"            "$AUDIO_DIR/vicious_02.mp3"
dl "$VICIOUS/Kevin%20MacLeod%20-%2003%20-%20Lewis%20and%20DeKalb.mp3" "$AUDIO_DIR/vicious_03.mp3"
dl "$VICIOUS/Kevin%20MacLeod%20-%2004%20-%20Chillin%20Hard.mp3"    "$AUDIO_DIR/vicious_04.mp3"
dl "$VICIOUS/Kevin%20MacLeod%20-%2005%20-%20Basic%20Implosion.mp3" "$AUDIO_DIR/vicious_05.mp3"

echo "=== Audio: Jahzzar – Super (Pop/Funk, CC BY-SA 3.0) ==="
SUPER="$ARCHIVE/jamendo-174647"
dl "$SUPER/01-1520002-Jahzzar-Shake%20It_.mp3" "$AUDIO_DIR/super_01.mp3"
dl "$SUPER/02-1520003-Jahzzar-Chiefs.mp3"       "$AUDIO_DIR/super_02.mp3"
dl "$SUPER/03-1520006-Jahzzar-No%20Control.mp3" "$AUDIO_DIR/super_03.mp3"
dl "$SUPER/04-1520005-Jahzzar-Word%20Up.mp3"    "$AUDIO_DIR/super_04.mp3"
dl "$SUPER/05-1520004-Jahzzar-Comedie.mp3"      "$AUDIO_DIR/super_05.mp3"

echo ""
echo "=== Album artwork ==="
ARCH_IMG="https://archive.org/services/img"
dl "$ARCH_IMG/Cylinders-15736"                    "$ARTWORK_DIR/album_cylinders.jpg"
dl "$ARCH_IMG/Music_Inspired_by_MiNRS-22282"      "$ARTWORK_DIR/album_minrs.jpg"
# Kai Engel - prefer high-res iTunes artwork
dl "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/c5/65/9a/c5659a77-12df-336d-8f20-2d2f741e6028/5054316153313.png/600x600bb.jpg" \
   "$ARTWORK_DIR/album_idea.jpg"
dl "$ARCH_IMG/Kevin-MacLeod_Vicious_2016_FullAlbum" "$ARTWORK_DIR/album_vicious.jpg"
dl "$ARCH_IMG/jamendo-174647"                     "$ARTWORK_DIR/album_super.jpg"

echo ""
echo "=== Artist photos ==="
dl "http://r2.theaudiodb.com/images/media/artist/thumb/zabriskie-chris-5457fd34d1b49.jpg" \
   "$ARTWORK_DIR/artist_chris_zabriskie.jpg"
# Lee Rosevere / Kai Engel / Jahzzar not in TheAudioDB - reuse album art
[[ -f "$ARTWORK_DIR/album_minrs.jpg" ]]    && cp "$ARTWORK_DIR/album_minrs.jpg"    "$ARTWORK_DIR/artist_lee_rosevere.jpg"
[[ -f "$ARTWORK_DIR/album_idea.jpg" ]]     && cp "$ARTWORK_DIR/album_idea.jpg"     "$ARTWORK_DIR/artist_kai_engel.jpg"
[[ -f "$ARTWORK_DIR/album_super.jpg" ]]    && cp "$ARTWORK_DIR/album_super.jpg"    "$ARTWORK_DIR/artist_jahzzar.jpg"
dl "https://r2.theaudiodb.com/images/media/artist/thumb/i5nalu1658778454.jpg" \
   "$ARTWORK_DIR/artist_kevin_macleod.jpg"

echo ""
echo "=== Done. $(ls "$AUDIO_DIR"/*.mp3 2>/dev/null | wc -l | tr -d ' ') audio files, $(ls "$ARTWORK_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ') images in: $ASSETS_DIR ==="
echo ""
echo "Attribution required by licenses:"
echo "  Chris Zabriskie (CC BY 4.0) - https://chriszabriskie.com"
echo "  Lee Rosevere (CC BY 4.0)    - https://leerosevere.bandcamp.com"
echo "  Kai Engel (CC BY 4.0)       - https://freemusicarchive.org/music/Kai_Engel"
echo "  Kevin MacLeod (CC BY 4.0)   - https://incompetech.com"
echo "  Jahzzar (CC BY-SA 3.0)      - https://jahzzar.bandcamp.com"
