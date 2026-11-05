"""Capture UI test checkpoints from an explicitly selected Simulator display.

Usage: python3 tools/appstore/capture-native-display.py UDID en|es DISPLAY OUTPUT [TEST ...]
Use Device Hub's Open/Closed controls to change Duo posture before running.
"""
import subprocess,sys,threading,time,json,re,struct
from pathlib import Path
if len(sys.argv)<5:
 print(__doc__);sys.exit(2)
udid,language,display,output=sys.argv[1:5]
tests=sys.argv[5:] or ['testAppStoreScreenshots','testVoiceSetupThreePaths']
root=Path(output);root.mkdir(parents=True,exist_ok=True)
stop=threading.Event();failures=[];captured=[]
def watch():
 container=None;last=None
 while not stop.is_set():
  try:
   if container is None or not container.exists():
    p=subprocess.run(['xcrun','simctl','get_app_container',udid,'ai.nodus.reader.uitests.xctrunner','data'],capture_output=True,text=True)
    if p.returncode:time.sleep(1);continue
    container=Path(p.stdout.strip())/'Documents'
   request=container/'nodus-capture-request.json'
   if request.exists():
    item=json.loads(request.read_text())
    if item['token']!=last:
     name=re.sub(r'[^\w.-]','-',item['name'])
     target=root/(name+'.png')
     subprocess.run(['xcrun','simctl','io',udid,'screenshot']+([] if display=='default' else ['--display='+display])+[str(target)],check=True,capture_output=True)
     size=struct.unpack('>II',target.read_bytes()[16:24])
     captured.append({'name':item['name'],'file':str(target),'size':size})
     (root/'manifest.json').write_text(json.dumps(captured,indent=2))
     (container/'nodus-capture-ack.txt').write_text(item['token'])
     last=item['token'];print('Captured',name,size,flush=True)
  except Exception as error:
   failures.append(str(error));print('Capture error',error,flush=True);return
  time.sleep(.1)
# Discard only the previous synthetic test handshake before starting the runner.
p=subprocess.run(['xcrun','simctl','get_app_container',udid,'ai.nodus.reader.uitests.xctrunner','data'],capture_output=True,text=True)
if p.returncode==0:
 for name in ['nodus-capture-request.json','nodus-capture-ack.txt']:
  (Path(p.stdout.strip())/'Documents'/name).unlink(missing_ok=True)
thread=threading.Thread(target=watch,daemon=True);thread.start()
import os
env=os.environ.copy();env['TEST_RUNNER_NODUS_APPSTORE_LANG']=language;env['TEST_RUNNER_NODUS_EXTERNAL_CAPTURE']='1'
action='test-without-building' if env.get('NODUS_CAPTURE_WITHOUT_BUILD')=='1' else 'test'
derived=env.get('NODUS_CAPTURE_DERIVED_DATA','/tmp/nodus-reader-build55-sim-release')
packages=env.get('NODUS_CAPTURE_PACKAGES','build/SourcePackages-release55')
args=['xcodebuild','-project','NodusReader.xcodeproj','-scheme','NodusReader','-configuration','Debug','-destination','platform=iOS Simulator,id='+udid,'-derivedDataPath',derived,'-clonedSourcePackagesDirPath',packages,'-disableAutomaticPackageResolution',action]+['-only-testing:NodusReaderUITests/NodusReaderUITests/'+t for t in tests]
if action=='test-without-building' and env.get('NODUS_CAPTURE_XCTESTRUN'):
 args=['xcodebuild',action,'-xctestrun',env['NODUS_CAPTURE_XCTESTRUN'],'-destination','platform=iOS Simulator,id='+udid]+['-only-testing:NodusReaderUITests/NodusReaderUITests/'+t for t in tests]
bundle=root.resolve()/('Test-'+str(time.time_ns())+'.xcresult')
args+=['-resultBundlePath',str(bundle),'-collect-test-diagnostics','never']
(root/'run.json').write_text(json.dumps({'device':udid,'language':language,'display':display,'tests':tests,'resultBundle':str(bundle)},indent=2))

with (root/'test.log').open('w') as log:
 result=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT)
stop.set();thread.join(timeout=5)
print('Test exit',result.returncode,'captures',len(captured),'capture errors',failures,flush=True)
sys.exit(result.returncode or bool(failures))
