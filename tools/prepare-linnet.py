#!/usr/bin/env python3
"""Repackage the pinned Apache-2.0 static SDK as frameworks to isolate its headers.
No model weights are downloaded or changed. Run automatically by XcodeGen.
"""
import hashlib, pathlib, plistlib, shutil, tempfile, urllib.request, zipfile
root = pathlib.Path(__file__).resolve().parents[1]
package = root / 'Modules/LinnetTTS'
out = package / 'CLinnetTTS.xcframework'
if (out / 'nodus-package-v3').exists():
    raise SystemExit(0)
url = 'https://github.com/VoxRT/LinnetTTS/releases/download/v0.1.1/LinnetTTS-0.1.1.xcframework.zip'
checksum = '83990ef6ab979857cc66dd57c903b80c180f533a55007e6cec5907d898caed64'
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    archive = tmp / 'sdk.zip'
    urllib.request.urlretrieve(url, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise SystemExit('Linnet SDK checksum mismatch')
    with zipfile.ZipFile(archive) as z:
        z.extractall(tmp / 'extracted')
    source = next((tmp / 'extracted').rglob('LinnetTTS.xcframework'))
    info = plistlib.loads((source / 'Info.plist').read_bytes())
    staging = tmp / 'CLinnetTTS.xcframework'; staging.mkdir()
    for lib in info['AvailableLibraries']:
        original = source / lib['LibraryIdentifier']
        fw = staging / lib['LibraryIdentifier'] / 'CLinnetTTS.framework'; fw.mkdir(parents=True)
        shutil.copy2(original / lib['LibraryPath'], fw / 'CLinnetTTS')
        shutil.copytree(original / lib['HeadersPath'], fw / 'Headers')
        (fw / 'Modules').mkdir()
        shutil.move(fw / 'Headers/module.modulemap', fw / 'Modules/module.modulemap')
        (fw / 'Modules/module.modulemap').write_text('framework module CLinnetTTS {\n  umbrella header "linnet_tts.h"\n  export *\n}\n')
        (fw / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='CLinnetTTS', CFBundleIdentifier='com.voxrt.CLinnetTTS', CFBundleName='CLinnetTTS', CFBundlePackageType='FMWK', CFBundleVersion='1', CFBundleShortVersionString='0.1.1')))
        metadata = plistlib.loads((fw / 'Info.plist').read_bytes())
        metadata['CFBundleInfoDictionaryVersion'] = '6.0'
        metadata['CFBundleDevelopmentRegion'] = 'en'
        if lib['SupportedPlatform'] == 'ios':
            metadata['MinimumOSVersion'] = '15.0'
            metadata['CFBundleSupportedPlatforms'] = ['iPhoneSimulator' if lib.get('SupportedPlatformVariant') == 'simulator' else 'iPhoneOS']
        else:
            metadata['LSMinimumSystemVersion'] = '12.0'
            metadata['CFBundleSupportedPlatforms'] = ['MacOSX']
        (fw / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        if lib['SupportedPlatform'] == 'macos':
            version = fw / 'Versions/A'; version.mkdir(parents=True)
            for name in ['CLinnetTTS', 'Headers', 'Modules']:
                shutil.move(fw / name, version / name)
            (version / 'Resources').mkdir()
            shutil.move(fw / 'Info.plist', version / 'Resources/Info.plist')
            (fw / 'Versions/Current').symlink_to('A')
            for name in ['CLinnetTTS', 'Headers', 'Modules', 'Resources']:
                (fw / name).symlink_to('Versions/Current/' + name)
        lib['LibraryPath'] = 'CLinnetTTS.framework'; lib.pop('BinaryPath', None); lib.pop('HeadersPath', None)
    (staging / 'Info.plist').write_bytes(plistlib.dumps(info))
    (staging / 'nodus-package-v3').touch()
    if out.exists(): shutil.rmtree(out)
    shutil.copytree(staging, out, symlinks=True)
