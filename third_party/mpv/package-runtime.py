"""校验源码，打包 libmpv/ANGLE 的 DLL 依赖闭包及许可信息。"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inputs(package):
    return '\n'.join(
        f'{sha256(package / name)}  {name}'
        for name in ['source.tar.gz', 'source.json', 'build.sh',
                     'packages.txt', 'package-runtime.py', 'windows-test-names.patch']
    ) + '\n'


def extract(package, build):
    source = json.loads((package / 'source.json').read_text(encoding='utf-8'))
    if sha256(package / 'source.tar.gz') != source['source_sha256']:
        raise RuntimeError('mpv source archive SHA-256 mismatch')
    stamp = build / 'source.sha256'
    if stamp.exists():
        if stamp.read_text().strip() != source['source_sha256']:
            raise RuntimeError('Source changed; use a fresh build/mpv directory')
    else:
        with tarfile.open(package / 'source.tar.gz') as archive:
            archive.extractall(build / 'source', filter='data')
        stamp.write_text(source['source_sha256'] + '\n', newline='\n')
    # 测试程序避免 .mkv.exe 双后缀；保留 fixture、用例名和断言。
    samples = build / 'source/mpv/test/samples/meson.build'
    patch = (package / 'windows-test-names.patch').read_text(encoding='utf-8').splitlines()
    removed = [line[1:] for line in patch if line.startswith('-') and not line.startswith('---')]
    added = [line[1:] for line in patch if line.startswith('+') and not line.startswith('+++')]
    if len(removed) != 1 or len(added) != 1:
        raise RuntimeError('Expected the single-line Windows test-name patch')
    original, patched = removed[0], added[0]
    text = samples.read_text(encoding='utf-8')
    if original in text:
        samples.write_text(text.replace(original, patched), encoding='utf-8', newline='\n')
    elif patched not in text:
        raise RuntimeError('Windows test-name patch no longer applies')


def package_runtime(package, build, prefix):
    runtime = build / 'runtime'
    runtime.mkdir(exist_ok=True)
    bin_dir = prefix / 'bin'
    available = {p.name.lower(): p for p in bin_dir.glob('*.dll')}
    root_dll = build / 'compile/libmpv-2.dll'
    queue = [root_dll, bin_dir / 'libEGL.dll', bin_dir / 'libGLESv2.dll']
    copied = {}
    owners = set()
    ownership = {}
    while queue:
        dll = queue.pop()
        key = dll.name.lower()
        if key in copied:
            continue
        if not dll.is_file():
            raise RuntimeError(f'Missing DLL: {dll}')
        imports = subprocess.check_output(
            [str(bin_dir / 'objdump.exe'), '-p', str(dll)], text=True
        )
        for name in re.findall(r'DLL Name:\s*(\S+)', imports):
            dependency = available.get(name.lower())
            if dependency:
                queue.append(dependency)
            elif not (Path(os.environ['WINDIR']) / 'System32' / name).exists() \
                    and not name.lower().startswith(('api-ms-', 'ext-ms-')):
                raise RuntimeError(f'Unresolved dependency: {dll.name} -> {name}')
        shutil.copy2(dll, runtime / dll.name)
        copied[key] = dll

    # 一次查询全部 DLL 归属，避免逐文件重复扫描 pacman 数据库。
    msys_bin = subprocess.check_output(['cygpath', '-u', str(bin_dir)], text=True).strip()
    paths = [msys_bin + '/' + p.name for p in copied.values() if p.parent == bin_dir]
    owner_lines = subprocess.check_output(['pacman', '-Qo', *paths], text=True)
    for line in owner_lines.splitlines():
        path, package_version = line.rsplit(' is owned by ', 1)
        owner, _ = package_version.split(' ', 1)
        owners.add(owner)
        ownership[Path(path).name] = owner

    shutil.copy2(build / 'compile/libmpv.dll.a', runtime / 'libmpv.dll.a')
    headers = runtime / 'include/mpv'
    headers.mkdir(parents=True, exist_ok=True)
    for header in (build / 'source/mpv/include/mpv').glob('*.h'):
        shutil.copy2(header, headers / header.name)
    licenses = runtime / 'licenses'
    licenses.mkdir(exist_ok=True)
    for name in ['LICENSE.GPL', 'LICENSE.LGPL', 'Copyright']:
        shutil.copy2(package / name, licenses / name)
    for owner in sorted(owners):
        short = owner.removeprefix('mingw-w64-ucrt-x86_64-')
        source = prefix / 'share/licenses' / short
        if source.is_dir():
            shutil.copytree(source, licenses / short, dirs_exist_ok=True)
    # pacman 元数据包含版本、上游地址和许可；所有运行 DLL 都保留包归属。
    metadata = subprocess.check_output(['pacman', '-Qi', *sorted(owners)], text=True)
    (licenses / 'MSYS2-PACKAGES.txt').write_text(metadata, encoding='utf-8', newline='\n')
    versions = subprocess.check_output(['pacman', '-Q', *sorted(owners)], text=True)
    (runtime / 'PACKAGES.txt').write_text(
        versions + '\n' + '\n'.join(f'{dll}: {owner}'
                                   for dll, owner in sorted(ownership.items())) + '\n',
        encoding='utf-8', newline='\n')
    (runtime / 'BUILD_INPUTS').write_text(inputs(package), encoding='utf-8', newline='\n')
    files = [runtime / p.name for p in copied.values()]
    files += [runtime / 'libmpv.dll.a', runtime / 'BUILD_INPUTS', runtime / 'PACKAGES.txt']
    files += list(headers.glob('*.h')) + [p for p in licenses.rglob('*') if p.is_file()]
    manifest = ''.join(f'{sha256(p)}  {p.relative_to(runtime).as_posix()}\n'
                       for p in sorted(files))
    (runtime / 'SHA256SUMS').write_text(manifest, encoding='utf-8', newline='\n')
    print(f'Packaged {len(copied)} DLLs, {sum(p.stat().st_size for p in files) / 1048576:.1f} MiB: {runtime}')
    prebuilt = package / 'prebuilt'
    prebuilt.mkdir(exist_ok=True)
    archive = prebuilt / 'windows-x64.zip'
    # 归档集中保留清单中的交付文件，固定 ZIP 元数据以便比较重建结果。
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for path in sorted([*files, runtime / 'SHA256SUMS']):
            info = zipfile.ZipInfo(path.relative_to(runtime).as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(info, path.read_bytes())
    (prebuilt / 'SHA256SUMS').write_text(
        f'{sha256(archive)}  windows-x64.zip\n', encoding='utf-8', newline='\n')
    print(f'Prebuilt archive: {archive} ({archive.stat().st_size / 1048576:.1f} MiB)')


def verify_prebuilt(package):
    prebuilt = package / 'prebuilt'
    expected = (prebuilt / 'SHA256SUMS').read_text().split()[0]
    archive = prebuilt / 'windows-x64.zip'
    if sha256(archive) != expected:
        raise RuntimeError('Prebuilt archive SHA-256 mismatch')
    with zipfile.ZipFile(archive) as source:
        if source.read('BUILD_INPUTS').decode() != inputs(package):
            raise RuntimeError('Prebuilt build inputs are outdated')
        for line in source.read('SHA256SUMS').decode().splitlines():
            expected, name = line.split('  ', 1)
            if hashlib.sha256(source.read(name)).hexdigest() != expected:
                raise RuntimeError(f'Prebuilt file SHA-256 mismatch: {name}')
    print('Prebuilt archive, build inputs and all runtime files verified.')


if __name__ == '__main__':
    action, package, *arguments = sys.argv[1:]
    if action == 'extract':
        extract(Path(package), Path(arguments[0]))
    elif action == 'package':
        package_runtime(Path(package), Path(arguments[0]), Path(arguments[1]))
    elif action == 'verify':
        verify_prebuilt(Path(package))
    else:
        raise ValueError(action)
