import json,sys
from wsgidav.wsgidav_app import WsgiDAVApp
from cheroot.wsgi import Server
app=WsgiDAVApp({'provider_mapping':{'/':sys.argv[1]},'simple_dc':{'user_mapping':{'*':True}},'verbose':0,'logging':{'enable':False}})
server=Server(('127.0.0.1',0),app,numthreads=2)
server.prepare()
print(json.dumps({'port':server.socket.getsockname()[1]}),flush=True)
server.serve()
