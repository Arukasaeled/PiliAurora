"""使用现有 libmpv 验证直载媒体的参数解析；不访问网络或安装依赖。"""

import argparse
import ctypes as c
import json
from pathlib import Path
import shutil
import subprocess
import time
import wave


class Event(c.Structure):
    _fields_ = [
        ("event_id", c.c_int),
        ("error", c.c_int),
        ("reply_userdata", c.c_uint64),
        ("data", c.c_void_p),
    ]


class LogMessage(c.Structure):
    _fields_ = [
        ("prefix", c.c_char_p), ("level", c.c_char_p), ("text", c.c_char_p),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument('--video', required=True, type=Path)
    parser.add_argument('--seek-target', type=float,
                        help='跳转至非关键帧位置，检查独立音轨恢复时的无声间隔')
    parser.add_argument('--keyframes-control', action='store_true',
                        help='使用旧关键帧策略复现无声，作为单变量对照')
    parser.add_argument('--audio-reload', action='store_true',
                        help='验证后台音轨重连保持视频时钟与暂停状态')
    args = parser.parse_args()
    library = args.library.resolve(strict=True)
    workspace = Path(__file__).resolve().parents[3]
    output = workspace / "build" / "native-playback-smoke"
    output.mkdir(parents=True, exist_ok=True)
    video = args.video.resolve(strict=True)
    audio = output / "generated-音频,;100%片段.wav"
    # 生成无账号数据的外部音轨，覆盖 Windows 路径与 UTF-8 转义。
    with wave.open(str(audio), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(8000)
        wav.writeframes(b"\0\0" * 8000 * max(
            20 if args.audio_reload else 3, int(args.seek_target or 0) + 3))

    mpv = c.CDLL(str(library))
    mpv.mpv_create.restype = c.c_void_p
    mpv.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    mpv.mpv_initialize.argtypes = [c.c_void_p]
    mpv.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
    mpv.mpv_command_async.argtypes = [
        c.c_void_p, c.c_uint64, c.POINTER(c.c_char_p)]
    mpv.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
    mpv.mpv_wait_event.restype = c.POINTER(Event)
    mpv.mpv_get_property_string.argtypes = [c.c_void_p, c.c_char_p]
    mpv.mpv_get_property_string.restype = c.c_void_p
    mpv.mpv_free.argtypes = [c.c_void_p]
    mpv.mpv_terminate_destroy.argtypes = [c.c_void_p]
    mpv.mpv_request_log_messages.argtypes = [c.c_void_p, c.c_char_p]
    handle = mpv.mpv_create()
    if not handle:
        raise RuntimeError("mpv_create failed")

    def require(condition, message):
        if not condition:
            raise RuntimeError(message)

    def property_value(name):
        pointer = mpv.mpv_get_property_string(handle, name.encode())
        if not pointer:
            return None
        try:
            return c.string_at(pointer).decode("utf-8")
        finally:
            mpv.mpv_free(pointer)

    def command(*values):
        argv = (c.c_char_p * (len(values) + 1))(
            *(value.encode("utf-8") for value in values), None
        )
        require(mpv.mpv_command(handle, argv) >= 0, f"{values[0]} failed")

    video_frames = 0
    native_errors = []

    def read_event(timeout):
        nonlocal video_frames
        event = mpv.mpv_wait_event(handle, timeout).contents
        if args.audio_reload and event.event_id == 2:
            log = c.cast(event.data, c.POINTER(LogMessage)).contents
            message = log.text.decode('utf-8')
            if log.level in (b'error', b'fatal'):
                native_errors.append(message.strip())
            if (log.prefix == b'cplayer'
                    and 'video_output_image: r=2/' in message):
                video_frames += 1
        return event

    def load(uri, options=""):
        # 清空上一轮事件，避免误把旧 file-loaded 作为新媒体加载完成。
        while read_event(0).event_id:
            pass
        command("loadfile", str(uri), "replace", "-1", options)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            event = read_event(0.1)
            if event.event_id == 7:  # MPV_EVENT_END_FILE
                end = c.cast(event.data, c.POINTER(c.c_int))
                if end[0] == 4:  # MPV_END_FILE_REASON_ERROR
                    raise RuntimeError(f"media load failed: mpv error {end[1]}, "
                                       f"context={native_errors[-4:]}")
            if event.event_id == 8:  # MPV_EVENT_FILE_LOADED
                return json.loads(property_value("track-list"))
        raise RuntimeError("file-loaded timeout")

    def wait_restart():
        deadline = time.monotonic() + 10
        gap = 0.0
        seeking = False
        while time.monotonic() < deadline:
            event = read_event(0.01)
            if event.event_id != 2:  # MPV_EVENT_LOG_MESSAGE
                continue
            log = c.cast(event.data, c.POINTER(LogMessage)).contents
            if log.prefix != b'cplayer':
                continue
            message = log.text.decode('utf-8')
            if 'Run command: seek' in message:
                seeking = True
            if not seeking:
                continue
            if 'delaying audio start' in message:
                gap = max(gap, float(message.split('diff=')[1]))
            if 'playback restart complete @' in message:
                require('video=playing' in message,
                        'seek fixture did not resume video')
                return gap
        raise RuntimeError('playback restart timeout')

    def reload_audio(request):
        tracks = json.loads(property_value('track-list'))
        track = next(t for t in tracks if t.get('external') and t['type'] == 'audio')
        before = float(property_value('time-pos') or 0)
        paused = property_value('pause')
        values = ['audio-reload', str(track['id'])]
        argv = (c.c_char_p * 3)(*(v.encode() for v in values), None)
        require(mpv.mpv_command_async(handle, request, argv) >= 0,
                'audio-reload was rejected')
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            event = read_event(0.05)
            require(event.event_id not in (8, 20),
                    'audio-reload reopened or sought the video')
            require(float(property_value('time-pos') or 0) >= before - 0.1,
                    'audio-reload reset the video clock')
            if event.event_id == 5 and event.reply_userdata == request:
                require(event.error >= 0, 'audio-reload failed')
                require(property_value('pause') == paused,
                        'audio-reload changed the pause state')
                return before
        raise RuntimeError('audio-reload reply timeout')

    try:
        for key, value in {
            "config": "no", "vo": "null", "ao": "null", "hwdec": "no",
            "pause": "yes", "terminal": "no",
        }.items():
            require(mpv.mpv_set_option_string(handle, key.encode(), value.encode())
                    >= 0, f"option {key} failed")
        require(mpv.mpv_initialize(handle) >= 0, "mpv_initialize failed")
        if args.audio_reload:
            require(mpv.mpv_request_log_messages(handle, b'trace') >= 0,
                    'video frame logging failed')
        options = f"audio-files-append=%{len(str(audio).encode('utf-8'))}%{audio}"
        tracks = load(video, options)
        require(any(t["type"] == "video" for t in tracks), "video missing")
        external = [t for t in tracks if t.get("external")]
        require(len(external) == 1 and external[0]["external-filename"] == str(audio)
                and external[0]["selected"], "external audio not selected")
        require(property_value("path") == str(video), "main URL was wrapped")
        # 与应用刷新路径一致，重用 file-local extras 并恢复起始时间。
        tracks = load(video, f"start=1.000,{options}")
        require(any(t.get("external") and t.get("selected") for t in tracks),
                "reload lost external audio")
        require(float(property_value("time-pos") or 0) >= 0.9,
                "reload did not restore position")
        tracks = load(video)
        require(not any(t.get("external") for t in tracks),
                "external audio leaked into next media")
        tracks = load(audio)
        require(all(t["type"] == "audio" for t in tracks),
                "audio-only unexpectedly opened video")
        if args.audio_reload:
            load(video, options)
            require(float(property_value('duration') or 0) > 3,
                    'audio-reload fixture must exceed 3 seconds')
            command('set', 'pause', 'no')
            # 等待开播事件稳定，再检查重连是否重新加载或跳转了视频。
            until = time.monotonic() + 3
            while time.monotonic() < until:
                read_event(0.05)
                if float(property_value('audio-pts') or 0) > 0.4:
                    break
            require(video_frames > 0, 'video output did not receive frames')
            before_video_frames = video_frames
            before = reload_audio(101)
            until = time.monotonic() + 3
            restored = False
            while time.monotonic() < until:
                read_event(0.05)
                pts = property_value('audio-pts')
                if (pts is not None and float(pts) > before + 0.2
                        and video_frames > before_video_frames):
                    restored = True
                    break
            require(restored, 'audio clock did not resume after audio-reload')
            require(video_frames > before_video_frames,
                    'video output did not keep receiving frames during audio recovery')
            command('set', 'pause', 'yes')
            # 覆盖故障音轨已经被取消选中的情形。
            command('set', 'aid', 'no')
            before = reload_audio(102)
            require(abs(float(property_value('time-pos') or 0) - before) < 0.1,
                    'paused audio recovery moved the video')
        seek_gaps = []
        if args.seek_target is not None:
            require(args.seek_target > 0, 'seek target must be positive')
            dart = shutil.which('dart')
            require(dart is not None, 'Dart is required for the seek smoke test')
            require(mpv.mpv_request_log_messages(handle, b'debug') >= 0,
                    'request log messages failed')
            seeks = []
            for target in [args.seek_target, args.seek_target / 2, args.seek_target]:
                argv = [dart, 'run', str(workspace / 'tool/probes/playback/native_seek_command.dart'),
                        str(target)]
                if args.keyframes_control:
                    argv.append('--keyframes-control')
                seeks.append((target, json.loads(subprocess.check_output(
                    argv, cwd=workspace, text=True))))
            load(video, options)
            require(float(property_value('duration') or 0) > args.seek_target + 0.2,
                    'video fixture is too short for the seek target')
            # load 在 file-loaded 返回，重启日志可能已经在其等待期间被消费。
            # 先在暂停媒体上完成一次跳转，再解除暂停，统一后续观测边界。
            command('seek', '0', 'absolute+exact')
            wait_restart()
            command('set', 'pause', 'no')
            for target, seek in seeks:
                # 使用正式 Dart 构造器；前进、后退、重复跳转均检查实际 mpv 时序。
                command(*seek)
                gap = wait_restart()
                seek_gaps.append({'target': target, 'command': seek, 'audio_gap_s': gap})
                print(json.dumps(seek_gaps[-1]))
                require(gap < 0.1,
                        f'video resumes {gap:.3f}s before external audio')
        print(json.dumps({
            "mpv": property_value("mpv-version"),
            "unicode_delimiter_audio_loaded": True,
            **({"audio_reload_preserves_video_and_pause": True}
               if args.audio_reload else {}),
            "reload_preserves_audio_and_start": True,
            "next_media_clears_external_audio": True,
            "audio_only": True,
            "seek_audio_gaps": seek_gaps,
        }))
    finally:
        mpv.mpv_terminate_destroy(handle)


if __name__ == "__main__":
    main()
