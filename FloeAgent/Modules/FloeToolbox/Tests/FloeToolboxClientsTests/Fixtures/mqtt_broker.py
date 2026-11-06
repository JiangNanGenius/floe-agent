import json, os, signal, socket, subprocess, sys, tempfile, time
root=tempfile.TemporaryDirectory(prefix='floe-mqtt-')
sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
config=os.path.join(root.name,'broker.conf')
with open(config,'w') as f:f.write('listener %d 127.0.0.1\nallow_anonymous true\npersistence false\nlog_dest stderr\n' % port)
log=open(os.path.join(root.name,'broker.log'),'wb')
process=subprocess.Popen([sys.argv[1],'-c',config],stdout=log,stderr=log)
def stop(*args):
 if process.poll() is None:process.terminate();process.wait(timeout=3)
 log.close();root.cleanup();sys.exit(0)
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
for _ in range(200):
 if process.poll() is not None:raise RuntimeError('loopback broker failed')
 try:
  client=socket.create_connection(('127.0.0.1',port),timeout=.05);client.close();break
 except OSError:time.sleep(.01)
else:stop()
print(json.dumps({'port':port}),flush=True)
while True:time.sleep(1)
