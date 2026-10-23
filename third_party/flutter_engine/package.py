"""打包、校验和解压固定版本的 Release 引擎。"""
import argparse
import gzip
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parents[1] / 'tool/engine'))
import engine_identity as protocol

TARGETS = {
    'android-arm': ('androidFramePlan', 'arm', 'libflutter.so'),
    'android-arm64': ('androidFramePlan', 'arm64', 'libflutter.so'),
    'android-x64': ('androidFramePlan', 'x64', 'libflutter.so'),
    'windows-x64': ('windowsDwmPaced', 'x64', 'flutter_windows.dll'),
}


def unpack(target, output):
    profile, architecture, name = TARGETS[target]
    source = ROOT / 'prebuilt' / target
    output.mkdir(parents=True, exist_ok=True)
    # 先校验临时文件，通过后再替换调用方输出。
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        staged = Path(temporary) / name
        with gzip.open(source / (name + '.gz'), 'rb') as src, staged.open('wb') as dst:
            shutil.copyfileobj(src, dst)
        shutil.copyfile(source / 'engine-identity.json', staged.with_name('engine-identity.json'))
        identity = protocol.validate_engine(staged, profile=profile, mode='release', architecture=architecture)
        shutil.copyfile(staged, output / name)
        protocol.write_json(output / 'engine-identity.json', identity)
    return identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['pack', 'unpack', 'verify', 'install-windows'])
    parser.add_argument('--target', choices=TARGETS, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    profile, architecture, name = TARGETS[args.target]
    if args.command == 'pack':
        if not args.library:
            parser.error('pack requires --library')
        identity = protocol.validate_engine(args.library, profile=profile, mode='release', architecture=architecture)
        destination = ROOT / 'prebuilt' / args.target
        destination.mkdir(parents=True, exist_ok=True)
        with (destination / (name + '.gz')).open('wb') as archive:
            with gzip.GzipFile(fileobj=archive, mode='wb', filename='', mtime=0) as compressed:
                with args.library.open('rb') as library:
                    shutil.copyfileobj(library, compressed)
        protocol.write_json(destination / 'engine-identity.json', identity)
    elif args.command == 'verify':
        with tempfile.TemporaryDirectory() as temporary:
            identity = unpack(args.target, Path(temporary))
    else:
        if not args.output:
            parser.error('output directory is required')
        if args.command == 'install-windows' and args.target != 'windows-x64':
            parser.error('install-windows requires windows-x64')
        identity = unpack(args.target, args.output)
        if args.command == 'install-windows':
            # AOT 中的呈现配置必须与最终打包的 DLL 一致。
            configuration = json.loads((ROOT.parents[1] / 'build/windows-engine-config.json').read_text())
            if configuration['identityDigest'] != protocol.identity_digest(identity):
                raise ValueError('Windows application configuration differs from packaged engine')
            shutil.copyfile(ROOT / 'NOTICE.windows.md', args.output / 'license.windows_flutter.md')
    print(json.dumps({'identity': identity, 'identityDigest': protocol.identity_digest(identity),
                      'dartDefines': protocol.dart_defines(profile, identity)}))


if __name__ == '__main__':
    main()
