"""记录构建输入并校验 Windows cnativeapi 预编译包。"""
from pathlib import Path
import hashlib
import sys
import zipfile
import re

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'third_party/nativeapi'
SOURCE = ROOT / 'third_party/cnativeapi'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inputs():
    files = [p for directory in ['src', 'cxx_impl']
             for p in (SOURCE / directory).rglob('*') if p.is_file()]
    files += [PACKAGE / n for n in ['CMakeLists.txt', 'build.ps1', 'package.py']]
    return ''.join(f'{digest(p.read_bytes())}  {p.relative_to(ROOT).as_posix()}\n'
                   for p in sorted(files))


def verify():
    archive = PACKAGE / 'prebuilt/windows-x64.zip'
    expected = (archive.parent / 'SHA256SUMS').read_text().split()[0]
    if digest(archive.read_bytes()) != expected:
        raise RuntimeError('Archive SHA256 mismatch')
    with zipfile.ZipFile(archive) as z:
        if z.read('BUILD_INPUTS').decode() != inputs():
            raise RuntimeError('Build inputs changed')
        for line in z.read('SHA256SUMS').decode().splitlines():
            expected, name = line.split('  ', 1)
            if digest(z.read(name)) != expected:
                raise RuntimeError(f'File mismatch: {name}')
    print('cnativeapi archive, build inputs and runtime verified')


if __name__ == '__main__':
    if sys.argv[1] == 'package':
        compiler_file = next((ROOT / 'build/nativeapi/CMakeFiles').glob('*/CMakeCXXCompiler.cmake'))
        compiler = compiler_file.read_text()
        toolchain = '\n'.join(re.findall(r'set\(CMAKE_CXX_COMPILER_(?:ID|VERSION) "[^"\n]+"\)', compiler))
        files = {'cnativeapi.dll': Path(sys.argv[2]).read_bytes(),
                 'BUILD_INFO': (toolchain + '\nArchitecture: x64\nConfiguration: Release\nCRT: static (/MT)\nWinUI3: OFF\n').encode(),
                 'BUILD_INPUTS': inputs().encode(),
                 'licenses/cnativeapi-LICENSE': (SOURCE / 'LICENSE').read_bytes(),
                 'licenses/nativeapi-LICENSE': (SOURCE / 'cxx_impl/LICENSE').read_bytes()}
        files['SHA256SUMS'] = ''.join(f'{digest(data)}  {name}\n'
                                      for name, data in sorted(files.items())).encode()
        directory = PACKAGE / 'prebuilt'
        directory.mkdir(exist_ok=True)
        archive = directory / 'windows-x64.zip'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name)
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, data)
        (directory / 'SHA256SUMS').write_text(
            f'{digest(archive.read_bytes())}  windows-x64.zip\n', encoding='utf-8')
    verify()
