import json,logging,socket,sys,threading,time
from pymodbus.datastore import ModbusServerContext,ModbusSlaveContext,ModbusSequentialDataBlock
from pymodbus.server import StartTcpServer
logging.getLogger('pymodbus').setLevel(logging.CRITICAL)
s=socket.socket();s.bind(('127.0.0.1',0));port=s.getsockname()[1];s.close()
device=ModbusSlaveContext(hr=ModbusSequentialDataBlock(0,list(range(1000))),ir=ModbusSequentialDataBlock(0,list(range(1000))),co=ModbusSequentialDataBlock(0,[False]*1000),di=ModbusSequentialDataBlock(0,[False]*1000),zero_mode=True)
context=ModbusServerContext(slaves=device,single=True)
threading.Thread(target=lambda:StartTcpServer(context=context,address=('127.0.0.1',port)),daemon=True).start()
for _ in range(300):
 try:
  c=socket.create_connection(('127.0.0.1',port),timeout=.05);c.close();break
 except OSError:time.sleep(.01)
else:raise RuntimeError('loopback Modbus server not ready')
print(json.dumps({'port':port}),flush=True)
while True:time.sleep(1)
