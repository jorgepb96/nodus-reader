import sys,subprocess,plistlib,zipfile,hashlib,json,re
from pathlib import Path
root=Path(__file__).resolve().parents[2]
platform=sys.argv[1]
# The marketing version the archive must carry, read from project.yml.
expected=re.search(r'MARKETING_VERSION: "([^"]+)"',(root/'project.yml').read_text()).group(1)
number=sys.argv[2] if len(sys.argv)>2 else "57"
if platform=='ios':
 package=root/f'build/export-ios-{number}/Nodus Reader.ipa'
 target=root/f'build/verify-ios-{number}'
 target.mkdir(exist_ok=True)
 with zipfile.ZipFile(package) as archive: archive.extractall(target)
else:
 package=root/f'build/export-macOS-{number}/Nodus Reader.pkg'
 target=root/f'build/verify-mac-{number}'
 subprocess.run(['pkgutil','--check-signature',str(package)],check=True,stdout=subprocess.DEVNULL)
 if not target.exists(): subprocess.run(['pkgutil','--expand-full',str(package),str(target)],check=True)
app=next(target.rglob('Nodus Reader.app'))
info_path=app/'Info.plist' if platform=='ios' else app/'Contents/Info.plist'
info=plistlib.loads(info_path.read_bytes())
assert info['CFBundleVersion']==number and info['CFBundleShortVersionString']==expected
assert info['CFBundleIdentifier']=='ai.nodus.reader'
resources = app if platform=='ios' else app/'Contents/Resources'
for name in ['LinnetNotice.txt','LinnetCodeLicense.txt','LinnetWeightsLicense.txt','LinnetModelManifest.json']:
 assert (resources/name).is_file(), name
assert 'Wiseport' in (resources/'LinnetNotice.txt').read_text()
framework=app/'Frameworks/CLinnetTTS.framework/Info.plist' if platform=='ios' else app/'Contents/Frameworks/CLinnetTTS.framework/Resources/Info.plist'
frameworkInfo=plistlib.loads(framework.read_bytes())
assert frameworkInfo.get('MinimumOSVersion' if platform=='ios' else 'LSMinimumSystemVersion')==('15.0' if platform=='ios' else '12.0')
assert json.loads((resources/'LinnetModelManifest.json').read_text())['revision']=='afd7578a5f5a9652788b9913bed9e7e961348062'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
r=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],check=True,capture_output=True)
ent=plistlib.loads(r.stdout)
assert ent['com.apple.developer.icloud-container-environment']=='Production'
assert 'iCloud.ai.nodus.reader' in ent['com.apple.developer.icloud-container-identifiers']
assert ent['com.apple.developer.team-identifier']=='6RPLS9EA4X'
assert not ent.get('get-task-allow',False) and not ent.get('com.apple.security.get-task-allow',False)
if platform=='ios':
 share=next((app/'PlugIns').glob('*.appex'))
 assert plistlib.loads((share/'Info.plist').read_bytes())['CFBundleVersion']==number
else: assert ent['com.apple.security.app-sandbox'] is True
binary=app/info['CFBundleExecutable'] if platform=='ios' else app/'Contents/MacOS'/info['CFBundleExecutable']
arch=subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()
assert arch=='arm64',arch
result={'platform':platform,'version':expected,'build':number,'sourceSnapshot':f'isolated source, build {number}','package':str(package.relative_to(root)),'bytes':package.stat().st_size,'sha256':hashlib.sha256(package.read_bytes()).hexdigest(),'signatureVerified':True,'productionICloud':True,'architecture':arch}
(root/f'build/Build{number}-{platform}-verification.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result))
