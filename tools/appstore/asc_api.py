import base64,json,time,urllib.request,urllib.error
from pathlib import Path
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec,utils
KEY=Path('/Users/jorgepb96/Documents/NODUS SIGNING/AuthKey_687TQG865G.p8')
def request(method,path,data=None):
    enc=lambda b:base64.urlsafe_b64encode(b).rstrip(b'=')
    now=int(time.time())
    token=enc(json.dumps({'alg':'ES256','kid':'687TQG865G','typ':'JWT'}).encode())+b'.'+enc(json.dumps({'iss':'36804ede-f0b5-4cd2-a273-c619feb6168f','iat':now-10,'exp':now+900,'aud':'appstoreconnect-v1'}).encode())
    key=serialization.load_pem_private_key(KEY.read_bytes(),password=None)
    r,s=utils.decode_dss_signature(key.sign(token,ec.ECDSA(hashes.SHA256())))
    token+=b'.'+enc(r.to_bytes(32,'big')+s.to_bytes(32,'big'))
    req=urllib.request.Request('https://api.appstoreconnect.apple.com'+path,data=json.dumps(data).encode() if data is not None else None,headers={'Authorization':'Bearer '+token.decode(),'Content-Type':'application/json'},method=method)
    try:
        with urllib.request.urlopen(req,timeout=60) as response:
            body=response.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(str(e.code)+' '+e.read().decode()) from None
if __name__=='__main__':
    result=request('GET','/v1/builds?filter[app]=6826844742&sort=-uploadedDate&limit=5&include=preReleaseVersion')
    print(json.dumps({'builds':[{'id':b['id'],'version':b['attributes']['version'],'processingState':b['attributes']['processingState']} for b in result['data']],'versions':result.get('included',[])},indent=2))
