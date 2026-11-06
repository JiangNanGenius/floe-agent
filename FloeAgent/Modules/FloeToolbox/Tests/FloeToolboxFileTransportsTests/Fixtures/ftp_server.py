import json,logging,sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler,TLS_FTPHandler
from pyftpdlib.servers import FTPServer
logging.getLogger('pyftpdlib').setLevel(logging.CRITICAL)
class Handler(TLS_FTPHandler if sys.argv[2]=='tls' else FTPHandler):
 def handle_ssl_established(self):
  print('synthetic control TLS established',file=sys.stderr,flush=True)
  return super().handle_ssl_established()
auth=DummyAuthorizer();auth.add_user('fixture','fixture-password',sys.argv[1],perm='elradfmwMT')
Handler.authorizer=auth;Handler.banner='Floe synthetic loopback FTP'
if sys.argv[2]=='tls':
 Handler.certfile=sys.argv[3];Handler.keyfile=sys.argv[4];Handler.tls_control_required=True;Handler.tls_data_required=True
server=FTPServer(('127.0.0.1',0),Handler)
print(json.dumps({'port':server.socket.getsockname()[1]}),flush=True)
server.serve_forever(timeout=.1,blocking=True,handle_exit=True)
