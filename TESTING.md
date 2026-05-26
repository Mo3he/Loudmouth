# Kenopsia - What to Test (Latest Build)

## Playback Engine
- [ ] Gapless playback between local tracks (no gap or click at transitions)
- [ ] Crossfade transitions: verify ReplayGain is applied to the incoming track's volume
- [ ] Interruption handling: pause/resume via phone call, Siri, or another app taking audio focus
- [ ] Route changes: switch between speaker, Bluetooth, AirPlay mid-playback
- [ ] Engine config change fallback: if AVAudioEngine fails, verify AVPlayer fallback kicks in
- [ ] Stall detection on slow network streams

## Source Playback
- [ ] Subsonic playback with self-signed HTTPS certificate (toggle in source settings)
- [ ] Backblaze B2 / cloud file playback (auth token in header, not URL)
- [ ] DLNA streaming from a local server
- [ ] Apple Music DRM tracks via MusicKit player
- [ ] Web Radio / HLS / Icecast streams

## Library & Scanner
- [ ] Full library scan populates `comment`, `bpm`, `isExplicit`, `rating` fields correctly
- [ ] Artwork cache keys are stable (no duplicate fetches after rescan)
- [ ] Stale Web Radio tracks are pruned on merge
- [ ] Excluded formats (DSD, OGG, Opus, WMA, MPC) are skipped during scan
- [ ] Source filter row in Library view filters tracks by source

## Smart Playlists
- [ ] Create a Smart Playlist with multiple rules (field + condition + value)
- [ ] Numeric conditions: "Rating is 5", "Year is 2020", greater/less than
- [ ] String conditions: contains, starts with, is
- [ ] Boolean fields: `isExplicit`
- [ ] Match operator (all/any) toggles correctly
- [ ] Limit + sort options apply

## Tag Editing
- [ ] Edit tags on MP3: verify untouched ID3 frames are preserved (including cover art)
- [ ] Edit tags on M4A: verify existing `covr` atom survives
- [ ] Edit tags on FLAC/Ogg: existing Vorbis comments preserved
- [ ] `AlbumEditorView`: batch-edit writes through TagWriter for all local-file tracks

## Artwork
- [ ] ArtworkFixerView auto-fix uses correct cache key and stamps all album tracks
- [ ] Manual artwork picker stores and displays correctly
- [ ] MusicBrainz fetch respects rate limiting
- [ ] DLNA direct artwork URL download path works

## Now Playing
- [ ] Lyrics view shows lyrics with empty-state when none available; close button works
- [ ] Tag editor sheet opens from Now Playing
- [ ] Queue view updates in real-time when tracks are added/removed/reordered
- [ ] VU meter displays (visual only)

## ShazamKit / Music Recognition
- [ ] Tap "identify song" and verify ShazamKit returns a match
- [ ] Matched song info displays correctly

## CarPlay
- [ ] CarPlay tab bar renders on connect
- [ ] Library changes (new scan, playlist edit) trigger tab bar rebuild via `.libraryDidChange`
- [ ] Disconnect cleans up the observer

## Widget
- [ ] Widget shows current now-playing info
- [ ] Play/pause toggle button works while audio is active (known: won't work when app is suspended)

## watchOS Companion
- [ ] Now Playing view mirrors iPhone playback state
- [ ] "iPhone not reachable" banner appears when phone disconnects
- [ ] Play/pause/skip commands from watch control iPhone playback

## Offline Cache
- [ ] Download progress UI (OfflineCacheProgress) updates in real-time
- [ ] Timeout config prevents hanging on slow connections

## EQ
- [ ] Applying an EQ preset persists across app relaunch
- [ ] 10-band EQ adjustments audibly affect playback

## Onboarding
- [ ] Final page "Add Your First Source" navigates to SourcesView
- [ ] "Skip for now" dismisses onboarding

## iPad
- [ ] No double-wrapped NavigationStack (single nav context in split view)
- [ ] Library and Now Playing display correctly in the content column

## History / Recently Played
- [ ] New plays appear immediately in the History tab (live observation)
- [ ] Tapping a history row starts playback of that track

## Unit Tests
- [ ] Run Cmd+U and confirm all 33 tests pass (SmartPlaylistEvaluator, Queue, Playlist Codable)
