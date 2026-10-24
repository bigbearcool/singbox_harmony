#!/usr/bin/env python3
"""Inspect the actual packaged ELF files, not intermediate build artifacts."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('hap', type=Path)
args = parser.parse_args()
sdk = Path(os.environ.get('DEVECO_SDK_HOME', '/Applications/DevEco-Studio.app/Contents/sdk'))
readelf = sdk / 'default/openharmony/native/llvm/bin/llvm-readelf'

with tempfile.TemporaryDirectory() as temporary:
    files = {}
    with zipfile.ZipFile(args.hap) as package:
        for name in ('libsingbox.so', 'libsingboxbridge.so', 'libc++_shared.so'):
            path = Path(temporary) / name
            path.write_bytes(package.read(f'libs/arm64-v8a/{name}'))
            files[name] = path
    for name, path in files.items():
        header = subprocess.check_output([str(readelf), '-h', str(path)], text=True)
        assert 'AArch64' in header, f'{name}: not arm64'
        dynamic = subprocess.check_output([str(readelf), '-d', str(path)], text=True)
        for line in dynamic.splitlines():
            if '(NEEDED)' in line:
                assert '/' not in line.split('[')[-1], f'{name}: absolute library dependency'
            assert '(RPATH)' not in line and '(RUNPATH)' not in line, f'{name}: desktop runtime path'
        if name == 'libsingboxbridge.so':
            assert '[libsingbox.so]' in dynamic, 'bridge does not link core by portable name'
        if name == 'libsingbox.so':
            relocations = subprocess.check_output([str(readelf), '-r', str(path)], text=True)
            assert 'R_AARCH64_TLSDESC' in relocations, 'missing HarmonyOS TLS descriptor'
            assert 'R_AARCH64_TLS_TPREL' not in relocations, 'unsupported initial-exec TLS'
            symbols = subprocess.check_output([str(readelf), '--dyn-syms', '--wide', str(path)], text=True)
            for symbol in ('SBVersion', 'SBFree', 'SBCheck', 'SBStart', 'SBStop', 'SBStats'):
                assert any(line.rstrip().endswith(' ' + symbol) for line in symbols.splitlines()), f'missing {symbol}'
print('PASS: HAP contains arm64 core, bridge and C++ runtime; ABI and portable linkage/TLS verified.')
