#!/usr/bin/env python3
"""在本机 ANGLE 上检查硬解输出的绿色条带，使用生产渲染参数。"""
import argparse
import ctypes as c
import json
import os
from pathlib import Path
import re
import time

from PIL import Image


class Param(c.Structure):
    _fields_ = [('type', c.c_int), ('data', c.c_void_p)]


class FBO(c.Structure):
    _fields_ = [('fbo', c.c_int), ('w', c.c_int), ('h', c.c_int), ('format', c.c_int)]


class Event(c.Structure):
    _fields_ = [('id', c.c_int), ('error', c.c_int), ('userdata', c.c_uint64), ('data', c.c_void_p)]


class Log(c.Structure):
    _fields_ = [('prefix', c.c_char_p), ('level', c.c_char_p), ('text', c.c_char_p)]


def bind(lib, name, restype, *args):
    function = getattr(lib, name)
    function.restype, function.argtypes = restype, list(args)
    return function


def rendering_options(root):
    # 直接读取生产参数；移除修复后，同一命令应重新检测到条带。
    source = (root / 'third_party/media_kit/lib/src/player/native/player/real.dart').read_text(encoding='utf-8')
    properties = source.split('final properties = <String, String>{', 1)[1].split('\n    };', 1)[0]
    options = {}
    for key in ('scale', 'dscale', 'dither', 'correct-downscaling',
                'linear-downscaling', 'sigmoid-upscaling', 'hdr-compute-peak'):
        match = re.search(r"'" + re.escape(key) + r"': '([^']+)'", properties)
        if not match:
            raise RuntimeError(f'Production rendering option missing: {key}')
        options[key] = match[1]
    runtime = (root / 'lib/plugin/pl_player/playback/native_playback_runtime.dart').read_text(encoding='utf-8')
    creation = runtime.split('final options = {', 1)[1].split('\n    };', 1)[0]
    options.update(re.findall(r"if \(Platform.isWindows\) '([^']+)': '([^']+)'", creation))
    return options


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--library-dir', type=Path, default=root / 'build/windows/x64/runner/Release')
    parser.add_argument('--width', type=int, default=1920)
    parser.add_argument('--height', type=int, default=1080)
    parser.add_argument('--decoder', default='d3d11va')
    parser.add_argument('--control-dumb-mode', choices=('yes', 'no', 'auto'))
    parser.add_argument('--output-dir', type=Path, default=root / 'build/windows-video-sampling')
    args = parser.parse_args()
    if args.width < 1 or args.height < 1:
        parser.error('Output dimensions must be positive')
    video, libs = args.video.resolve(), args.library_dir.resolve()
    if not video.is_file():
        parser.error('Local video file missing')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    options = rendering_options(root)
    if args.control_dumb_mode:
        options['gpu-dumb-mode'] = args.control_dumb_mode

    dll_directory = os.add_dll_directory(str(libs))
    egl = c.WinDLL(str(libs / 'libEGL.dll'))
    gl = c.WinDLL(str(libs / 'libGLESv2.dll'))
    mpv = c.CDLL(str(libs / 'libmpv-2.dll'))
    ptr = c.c_void_p
    get_proc = bind(egl, 'eglGetProcAddress', ptr, c.c_char_p)
    platform_display = c.WINFUNCTYPE(ptr, c.c_uint, ptr, c.POINTER(c.c_int))(get_proc(b'eglGetPlatformDisplayEXT'))
    display = platform_display(0x3202, None, (c.c_int * 3)(0x3203, 0x3208, 0x3038))
    assert bind(egl, 'eglInitialize', c.c_uint, ptr, ptr, ptr)(display, None, None), 'EGL initialization failed'
    config, count = ptr(), c.c_int()
    attributes = (c.c_int * 13)(0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3033, 1, 0x3040, 4, 0x3038)
    assert bind(egl, 'eglChooseConfig', c.c_uint, ptr, ptr, ptr, c.c_int, ptr)(display, attributes, c.byref(config), 1, c.byref(count)) and count.value
    context = bind(egl, 'eglCreateContext', ptr, ptr, ptr, ptr, ptr)(display, config, None, (c.c_int * 3)(0x3098, 2, 0x3038))
    width, height = args.width, args.height
    surface = bind(egl, 'eglCreatePbufferSurface', ptr, ptr, ptr, ptr)(display, config, (c.c_int * 5)(0x3057, width, 0x3056, height, 0x3038))
    assert surface and context, 'EGL surface creation failed'
    make_current = bind(egl, 'eglMakeCurrent', c.c_uint, ptr, ptr, ptr, ptr)
    assert make_current(display, surface, surface, context)
    renderer = bind(gl, 'glGetString', c.c_char_p, c.c_uint)(0x1F01).decode()
    player = bind(mpv, 'mpv_create', ptr)()
    assert player, 'mpv_create failed'
    render = ptr()
    samples, messages, frames = [], [], 0
    try:
        option = bind(mpv, 'mpv_set_option_string', c.c_int, ptr, c.c_char_p, c.c_char_p)
        values = {'vo': 'libmpv', 'hwdec': args.decoder, 'ao': 'null', 'audio': 'no',
                  'terminal': 'no', 'video-sync': 'audio', **options}
        for key, value in values.items():
            assert option(player, key.encode(), value.encode()) >= 0, key
        assert bind(mpv, 'mpv_initialize', c.c_int, ptr)(player) >= 0
        bind(mpv, 'mpv_request_log_messages', c.c_int, ptr, c.c_char_p)(player, b'debug')
        get_property = bind(mpv, 'mpv_get_property_string', ptr, ptr, c.c_char_p)
        version_pointer = get_property(player, b'mpv-version')
        version = c.string_at(version_pointer).decode() if version_pointer else None
        bind(mpv, 'mpv_free', None, ptr)(version_pointer)

        getproc_type = c.CFUNCTYPE(ptr, ptr, c.c_char_p)
        callback = getproc_type(lambda _, name: get_proc(name))

        class Init(c.Structure):
            _fields_ = [('get_proc', getproc_type), ('ctx', ptr)]

        init, api = Init(callback, None), c.create_string_buffer(b'opengl')
        params = (Param * 3)(Param(1, c.cast(api, ptr)), Param(2, c.cast(c.pointer(init), ptr)), Param(0, None))
        assert bind(mpv, 'mpv_render_context_create', c.c_int, ptr, ptr, ptr)(c.byref(render), player, params) >= 0
        load = (c.c_char_p * 4)(b'loadfile', str(video).encode(), b'replace', None)
        assert bind(mpv, 'mpv_command_async', c.c_int, ptr, c.c_uint64, ptr)(player, 1, load) >= 0
        wait = bind(mpv, 'mpv_wait_event', c.POINTER(Event), ptr, c.c_double)
        update = bind(mpv, 'mpv_render_context_update', c.c_uint64, ptr)
        draw = bind(mpv, 'mpv_render_context_render', c.c_int, ptr, ptr)
        read = bind(gl, 'glReadPixels', None, c.c_int, c.c_int, c.c_int, c.c_int, c.c_uint, c.c_uint, ptr)
        finish = bind(gl, 'glFinish', None)
        pixels = (c.c_ubyte * (width * height * 4))()
        fbo = FBO(0, width, height, 0)
        draw_params = (Param * 2)(Param(3, c.cast(c.pointer(fbo), ptr)), Param(0, None))
        start = time.monotonic()
        while frames < 20 and time.monotonic() - start < 10:
            while True:
                event = wait(player, 0).contents
                if event.id == 0:
                    break
                if event.id == 2:
                    log = c.cast(event.data, c.POINTER(Log)).contents
                    message = (log.text or b'').decode(errors='replace').strip()
                    if 'hardware decoding' in message or 'Decoder format:' in message or 'dumb mode' in message:
                        messages.append(message)
            if update(render) & 1:
                assert draw(render, draw_params) >= 0
                frames += 1
                if frames >= 5:
                    finish()
                    read(0, 0, width, height, 0x1908, 0x1401, pixels)
                    data = bytes(pixels)
                    # 与 Windows 插件一样沿用 mpv 的默认翻转，读取行序对应视频画面。
                    green_rows = 0
                    for y in range(height - 1, -1, -1):
                        row = data[y * width * 4:(y + 1) * width * 4]
                        green = sum(row[x] < 10 and 40 < row[x + 1] < 100 and row[x + 2] < 10 for x in range(0, len(row), 4))
                        if green / width <= 0.95:
                            break
                        green_rows += 1
                    samples.append(green_rows)
            time.sleep(0.005)
        name = video.stem + ('-' + args.control_dumb_mode if args.control_dumb_mode else '-production')
        if samples:
            Image.frombytes('RGBA', (width, height), bytes(pixels)).save(args.output_dir / f'{name}.png')
        result = {'video': video.name, 'renderer': renderer, 'mpv': version, 'options': options,
                  'frames': frames, 'messages': messages, 'greenRowsByFrame': samples}
        (args.output_dir / f'{name}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(result, ensure_ascii=False))
        assert frames >= 20 and samples, 'Insufficient decoded frames'
        assert f'Using hardware decoding ({args.decoder}).' in messages, 'Requested decoder was not used'
        assert all(rows == 0 for rows in samples), 'Green strip reproduced'
    finally:
        if render:
            bind(mpv, 'mpv_render_context_free', None, ptr)(render)
        bind(mpv, 'mpv_terminate_destroy', None, ptr)(player)
        make_current(display, None, None, None)
        bind(egl, 'eglDestroySurface', c.c_uint, ptr, ptr)(display, surface)
        bind(egl, 'eglDestroyContext', c.c_uint, ptr, ptr)(display, context)
        bind(egl, 'eglTerminate', c.c_uint, ptr)(display)
        dll_directory.close()


if __name__ == '__main__':
    main()
