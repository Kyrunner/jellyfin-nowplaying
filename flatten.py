#!/usr/bin/env python3
"""Flatten Jellyfin /Sessions JSON (stdin) -> one compact line (stdout).

Separate from backend.sh on purpose: a bash heredoc and piped stdin cannot
coexist — the heredoc wins and python parses its own source instead of the
response. Also makes the transform testable on its own with a saved fixture.
"""
import json,sys

# argv[1] = Jellyfin base URL, so the link is built where Jellyfin knowledge already
# lives (this script) rather than in QML. Jellyfin 10.11 route: /web/#/details?id=…
BASE = (sys.argv[1].rstrip('/') if len(sys.argv) > 1 else '')
# argv[2] = the API endpoint (LAN). Posters are fetched by QML's Image directly, and
# they should not cross the public edge to do it. Falls back to BASE when unset so an
# older backend.sh keeps working.
API_BASE = (sys.argv[2].rstrip('/') if len(sys.argv) > 2 and sys.argv[2] else BASE)

# 180px tall is ~2x the rendered thumbnail on a HiDPI bar. Asking Jellyfin to resize
# means ~12KB per poster instead of a multi-megabyte original, and Jellyfin caches
# the scaled copy after the first request.
POSTER_MAX_HEIGHT = 180


def poster_url(npi):
    """Series poster for an episode, the item's own Primary otherwise.

    A series poster is what "poster artwork" means for TV: tall, recognisable, and
    identical across a season. An episode's own Primary is a still frame from that
    episode -- often a dark or ambiguous one -- so it is only used when there is no
    series behind it.

    No credential is attached. Jellyfin serves /Items/<id>/Images/* unauthenticated,
    which is what makes it safe to hand this straight to QML's Image; adding an
    api_key here would put a working token into QML and into anything logging it.

    The `tag` is the image's content hash. Without it a changed poster keeps serving
    from cache; with it the URL changes when the artwork does.
    """
    if not API_BASE:
        return None

    series_id = npi.get("SeriesId")
    series_tag = npi.get("SeriesPrimaryImageTag")
    if npi.get("Type") == "Episode" and series_id and series_tag:
        return (f"{API_BASE}/Items/{series_id}/Images/Primary"
                f"?tag={series_tag}&maxHeight={POSTER_MAX_HEIGHT}")

    item_id = npi.get("Id")
    own_tag = (npi.get("ImageTags") or {}).get("Primary")
    if item_id and own_tag:
        return (f"{API_BASE}/Items/{item_id}/Images/Primary"
                f"?tag={own_tag}&maxHeight={POSTER_MAX_HEIGHT}")

    # Music and some live content genuinely have no artwork. The panel hides the
    # thumbnail rather than showing a broken-image box.
    return None
try:
    sessions=json.load(sys.stdin)
    if not isinstance(sessions,list): raise ValueError
except Exception:
    sys.exit(1)

def ticks_to_sec(t):
    return int(t)//10_000_000 if isinstance(t,(int,float)) else 0

streams=[]
for s in sessions:
    npi=s.get("NowPlayingItem")
    if not npi:                      # idle session -> not "now playing"
        continue
    ps=s.get("PlayState") or {}
    ti=s.get("TranscodingInfo")      # present ONLY while transcoding
    item=npi.get("Name") or "Unknown"
    series=npi.get("SeriesName")
    if series and npi.get("Type")=="Episode":
        idx=npi.get("IndexNumber"); pa=npi.get("ParentIndexNumber")
        tag=f"S{pa:02d}E{idx:02d} " if isinstance(idx,int) and isinstance(pa,int) else ""
        title=f"{series} — {tag}{item}"
    else:
        year=npi.get("ProductionYear")
        title=f"{item} ({year})" if year else item

    entry={
      "title": title,
      "user": s.get("UserName") or "?",
      "device": s.get("DeviceName") or "?",
      "client": s.get("Client") or "?",
      "paused": bool(ps.get("IsPaused")),
      "position_sec": ticks_to_sec(ps.get("PositionTicks")),
      "duration_sec": ticks_to_sec(npi.get("RunTimeTicks")),
      "transcoding": ti is not None,
      # Mbps to one decimal: the number he actually reads
      "bitrate_mbps": None,
      "video_codec": None, "audio_codec": None,
      "reasons": [], "hw_accel": None,
      # His own curated label, straight off the video stream's DisplayTitle:
      # "DV P7 FEL CM v4.0 - 4K - HEVC [88.0 Mb/s]". Worth using verbatim because
      # Jellyfin CANNOT tell FEL from MEL itself — every P7 title reports
      # VideoRangeType=DOVIWithEL and ElPresentFlag=1, so only the label carries it.
      "video_label": None,
      "video_range": None,
      "item_id": npi.get("Id"),
      "poster_url": poster_url(npi),
      # Transport targets the SESSION, not the item: Jellyfin routes commands to the
      # client that is playing, so the same film on two devices is two controllable
      # things. Mirrors how ky.navidrome-remote keys control by player.
      "session_id": s.get("Id"),
      # Both flags are required. SupportsRemoteControl covers the /Command route,
      # SupportsMediaControl the /Playing one, and a client can advertise one without
      # the other — a web dashboard being the obvious case.
      "controllable": bool(s.get("SupportsRemoteControl")) and bool(s.get("SupportsMediaControl")),
      "can_seek": bool(ps.get("CanSeek")),
      "control_error": (
          "" if (s.get("SupportsRemoteControl") and s.get("SupportsMediaControl"))
          else "%s cannot be controlled remotely" % (s.get("Client") or "this client")
      ),
      "web_url": (f"{BASE}/web/#/details?id={npi.get('Id')}&serverId={npi.get('ServerId')}"
                  if BASE and npi.get("Id") else None),
    }
    if ti:
        br=ti.get("Bitrate")
        entry["bitrate_mbps"]=round(br/1_000_000,1) if isinstance(br,(int,float)) else None
        entry["video_codec"]=ti.get("VideoCodec"); entry["audio_codec"]=ti.get("AudioCodec")
        entry["reasons"]=ti.get("TranscodeReasons") or []
        entry["hw_accel"]=ti.get("HardwareAccelerationType")
        entry["video_direct"]=bool(ti.get("IsVideoDirect"))
        entry["audio_direct"]=bool(ti.get("IsAudioDirect"))
    else:
        # direct play: source bitrate comes off the media stream instead
        for ms in (npi.get("MediaStreams") or []):
            if ms.get("Type")=="Video" and isinstance(ms.get("BitRate"),(int,float)):
                entry["bitrate_mbps"]=round(ms["BitRate"]/1_000_000,1)
                entry["video_codec"]=ms.get("Codec"); break
    for ms in (npi.get("MediaStreams") or []):
        if ms.get("Type") != "Video":
            continue
        entry["video_range"]=ms.get("VideoRangeType") or ms.get("VideoRange")
        dt=ms.get("DisplayTitle")
        if dt:
            # Jellyfin appends its own " - Dolby Vision Profile 7.6 (HDR10)" tail to the
            # label; drop it so what shows is HIS naming, not ours plus theirs.
            entry["video_label"]=dt.split(" - Dolby Vision Profile")[0].strip()
        break

    streams.append(entry)

print(json.dumps({"ok":True,"error":None,"streams":streams}, separators=(",",":")))
