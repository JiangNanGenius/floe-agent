# SPDX-License-Identifier: MPL-2.0
"""Worker orchestration contracts with deterministic fake executables.

These tests exercise the real worker, process lifecycle and artifact protocol.
They do not qualify TeX engines or App environment authorization.
"""
from pathlib import Path
import base64,gzip,hashlib,json,os,signal,subprocess,sys,tempfile,time,unittest,uuid
from unittest import mock
WORKER=Path(__file__).resolve().parents[2]/'Backends/latex_worker.py'
FAKE=r'''#!/usr/bin/env python3
from pathlib import Path
import gzip,json,os,sys,time
name=Path(sys.argv[0]).name
if name=='bwrap':
    # Protocol fixture only; real namespaces are checked by the Linux matrix.
    if sys.argv[1:]==['--version']:print('bwrap deterministic fixture 1');raise SystemExit(0)
    command=sys.argv[sys.argv.index('--')+1:]
    if any('floe-latex-isolation-probe-v1' in arg for arg in command):
        print(json.dumps({'namespaces':{name:'fixture-child-'+name for name in ('mnt','pid','net','ipc','uts','user')},'status':{'CapInh':'0','CapPrm':'0','CapEff':'0','CapBnd':'0','CapAmb':'0','NoNewPrivs':'1'}}));raise SystemExit(0)
    os.execv(command[0],command)
if '--version' in sys.argv:print(name+' deterministic fixture 1');raise SystemExit(0)
if name in ['xelatex','lualatex','pdflatex','latex']:
    output=Path(next(a.split('=',1)[1] for a in sys.argv if a.startswith('-output-directory=')))
    mode=(Path.cwd()/'main.tex').read_text()
    (output/'process.pid').write_text(str(os.getpid()))
    if 'LOOP' in mode:
        while True:time.sleep(.05)
    with (output/'phases.log').open('a') as f:f.write(json.dumps({'program':name,'args':sys.argv[1:],'date':os.environ.get('SOURCE_DATE_EPOCH')})+'\n')
    if 'FAIL' in mode:
        (output/'document.log').write_text('./main.tex:4: Undefined control sequence.\n')
        raise SystemExit(1)
    (output/'document.aux').write_text('\\relax\n'+('\\@input{chapters/a.aux}' if 'BIBTEX' in mode else ''))
    if 'BIBTEX' in mode:
        (output/'chapters').mkdir(exist_ok=True);(output/'chapters/a.aux').write_text('\\bibdata{references}')
    if 'BIBER' in mode:(output/'document.bcf').write_text('fixture bcf')
    if 'INDEX' in mode:(output/'document.idx').write_text('fixture index')
    if 'LARGE' in mode:
        for i in range(50):(output/('asset'+str(i)+'.aux')).write_text('auxiliary')
    (output/'document.pdf').write_bytes(b'%PDF-1.4\nfixture artifact\n')
    (output/'document.log').write_text('Fixture engine completed\n')
    with gzip.open(output/'document.synctex.gz','wb') as f:f.write(('SyncTeX Version:1\nInput:1:'+str(Path.cwd()/'main.tex')+'\n').encode())
else:
    with (Path.cwd()/'phases.log').open('a') as f:f.write(json.dumps({'program':name,'args':sys.argv[1:]})+'\n')
    if name in ['bibtex','biber']:(Path.cwd()/'document.bbl').write_text('fixture bibliography')
'''
class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='floe-worker-contract-');self.addCleanup(self.temporary.cleanup)
        self.workspace=Path(self.temporary.name);self.project=str(uuid.uuid4());self.request_id=str(uuid.uuid4())
        self.root=self.workspace/'.floe-latex'/self.project/self.request_id
        (self.root/'Source').mkdir(parents=True);self.bin=self.workspace/'bin';self.bin.mkdir()
        # Protocol tests run on macOS too. Stub the parent's Linux namespace
        # observation only in this test driver, never in production resources.
        # The fake helper above returns a matching synthetic attestation.
        self.driver=self.workspace/'protocol_driver.py'
        self.driver.write_text("import sys\nnamespace={'__name__':'floe_worker_protocol_fixture'}\nexec(compile(open("+repr(str(WORKER))+",'rb').read(),"+repr(str(WORKER))+",'exec'),namespace)\nnamespace['namespace_ids']=lambda:{name:'fixture-parent-'+name for name in namespace['ISOLATION_NAMESPACES']}\nnamespace['main']()\n")
        for name in ['xelatex','lualatex','pdflatex','latex','bibtex','biber','makeindex','dvipdfmx','bwrap']:
            program=self.bin/name;program.write_text(FAKE);program.chmod(0o755)
        self.environment=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ['PATH'],PYTHONDONTWRITEBYTECODE='1')
        self.request=self.root/'request.json';self.write_request('Text')
    def write_request(self,text,**extra):
        data=text.encode();(self.root/'Source/main.tex').write_bytes(data)
        value={'protocol':'floe.latex.worker','version':1,'requestID':self.request_id,'environmentID':'test-linux-protocol-fixture','buildTimestamp':1794000000,'timeoutSeconds':10,'manifest':{'id':self.project,'revision':7,'mainFile':'main.tex','engine':'xeLaTeX','files':[{'path':'main.tex','byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()}]}}
        value.update(extra);self.request.write_text(json.dumps(value));return value
    def action(self,action,*arguments):
        p=subprocess.run([sys.executable,'-B',str(self.driver),action,'--request',str(self.request),*arguments],env=self.environment,capture_output=True,text=True,timeout=20)
        marker=next(l for l in p.stdout.splitlines() if l.startswith('FLOE_LATEX_RECEIPT '))
        return p,json.loads(base64.b64decode(marker.split(' ',1)[1]))
    def receipt(self):return json.loads((self.root/'receipt.json').read_text())
    def test_nested_bibliography_recorder_flags_date_and_source_map(self):
        self.write_request('BIBTEX INDEX')
        p,terminal=self.action('build');self.assertEqual(p.returncode,0,p.stderr);self.assertTrue(terminal['workerStopped'])
        receipt=self.receipt();paths={a['path'] for a in receipt['artifacts']}
        self.assertIn('chapters/a.aux',paths);self.assertIn('document.bbl',paths)
        phases=[json.loads(l) for l in (self.root/'Output/phases.log').read_text().splitlines()]
        self.assertIn('bibtex',[p['program'] for p in phases]);self.assertIn('makeindex',[p['program'] for p in phases])
        for phase in [p for p in phases if p['program']=='xelatex']:
            self.assertIn('-no-shell-escape',phase['args']);self.assertIn('-recorder',phase['args']);self.assertEqual(phase['date'],'1794000000')
        with gzip.open(self.root/'Output/document.synctex.gz','rb') as f:self.assertIn(b'Input:1:main.tex',f.read())
    def test_biber_selected_from_actual_bcf(self):
        self.write_request('BIBER');p,_=self.action('build');self.assertEqual(p.returncode,0,p.stderr)
        phases=(self.root/'Output/phases.log').read_text();self.assertIn('"program": "biber"',phases);self.assertNotIn('"program": "bibtex"',phases)
    def test_missing_isolation_fails_before_engine_and_probe_explains(self):
        (self.bin/'bwrap').unlink();self.environment['PATH']=str(self.bin)
        p,terminal=self.action('build');self.assertEqual(p.returncode,1);self.assertIn('bubblewrap',terminal['error'])
        self.assertFalse((self.root/'Output/process.pid').exists())
        p=subprocess.run([sys.executable,'-B',str(self.driver),'probe'],env=self.environment,capture_output=True,text=True,timeout=20)
        value=json.loads(base64.b64decode(p.stdout.split('FLOE_LATEX_RECEIPT ',1)[1]));self.assertEqual(value['engines'],{});self.assertIn('bubblewrap',value['unavailableReason'])
    def test_large_receipt_is_paged_and_cleanup_requires_exact_identity(self):
        self.write_request('LARGE');p,terminal=self.action('build');self.assertEqual(p.returncode,0,p.stderr)
        self.assertGreater(terminal['receiptBytes'],4096);self.assertLess(len(p.stdout),2048)
        data=b''
        while len(data)<terminal['receiptBytes']:
            _,piece=self.action('receipt','--offset',str(len(data)),'--length','1024');data+=base64.b64decode(piece['bytes'])
        self.assertEqual(hashlib.sha256(data).hexdigest(),terminal['receiptSHA256'])
        value=self.receipt();value['requestID']=str(uuid.uuid4());(self.root/'receipt.json').write_text(json.dumps(value))
        p=subprocess.run([sys.executable,'-B',str(self.driver),'cleanup','--request',str(self.request)],env=self.environment,capture_output=True)
        self.assertNotEqual(p.returncode,0);self.assertTrue(self.root.exists())
        (self.root/'receipt.json').write_bytes(data);p,value=self.action('cleanup');self.assertEqual(p.returncode,0,p.stderr);self.assertTrue(value['cleaned']);self.assertFalse(self.root.exists())
    def test_failure_retains_real_logs_for_repair(self):
        self.write_request('FAIL');p,terminal=self.action('build');self.assertEqual(p.returncode,1)
        self.assertTrue(terminal['workerStopped']);receipt=self.receipt();self.assertFalse(receipt['success'])
        self.assertIn('document.log',{a['path'] for a in receipt['artifacts']});self.assertEqual(receipt['revision'],7)
    def test_changed_source_fails_before_engine_starts(self):
        (self.root/'Source/main.tex').write_text('Changed after the manifest')
        p,terminal=self.action('build');self.assertEqual(p.returncode,1);self.assertTrue(terminal['workerStopped']);self.assertFalse((self.root/'Output/process.pid').exists())
    def test_symlink_input_and_traversal_artifact_read_are_rejected(self):
        target=self.workspace/'outside';target.write_text('Text');(self.root/'Source/main.tex').unlink();(self.root/'Source/main.tex').symlink_to(target)
        p,_=self.action('build');self.assertEqual(p.returncode,1)
        p=subprocess.run([sys.executable,'-B',str(self.driver),'read','--request',str(self.request),'--file','../request.json'],env=self.environment,capture_output=True)
        self.assertNotEqual(p.returncode,0)
    def test_timeout_joins_child(self):
        self.write_request('LOOP',timeoutSeconds=1);p,terminal=self.action('build');self.assertEqual(p.returncode,1);self.assertTrue(terminal['workerStopped'])
        pid=int((self.root/'Output/process.pid').read_text())
        with self.assertRaises(ProcessLookupError):os.kill(pid,0)
    def test_signal_cancellation_joins_child_before_receipt(self):
        self.write_request('LOOP');p=subprocess.Popen([sys.executable,'-B',str(self.driver),'build','--request',str(self.request)],env=self.environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(lambda:p.poll() is None and p.kill())
        pid_path=self.root/'Output/process.pid';deadline=time.monotonic()+5
        while not pid_path.exists() and time.monotonic()<deadline:time.sleep(.02)
        self.assertTrue(pid_path.exists());pid=int(pid_path.read_text());p.send_signal(signal.SIGTERM);stdout,stderr=p.communicate(timeout=5)
        self.assertNotEqual(p.returncode,0);receipt=self.receipt();self.assertTrue(receipt['cancelled']);self.assertTrue(receipt['workerStopped'])
        with self.assertRaises(ProcessLookupError):os.kill(pid,0)
    def test_root_and_nonroot_require_the_same_files_network_and_process_isolation(self):
        namespace={'__name__':'floe_worker_flag_contract'};exec(compile(WORKER.read_bytes(),str(WORKER),'exec'),namespace)
        for uid in (0,501):
            with mock.patch.object(os,'geteuid',return_value=uid),mock.patch.object(namespace['shutil'],'which',return_value=str(self.bin/'bwrap')):
                command=namespace['isolated_command'](['/usr/bin/true'])
            self.assertEqual('--unshare-user' in command,uid!=0)
            self.assertNotIn('--unshare-user-try',command)
            for flag in ['--unshare-net','--unshare-pid','--unshare-ipc','--unshare-uts','--clearenv','--ro-bind']:self.assertIn(flag,command)
            self.assertEqual(command[command.index('--cap-drop')+1],'ALL')
            payload=command[command.index('--')+1:]
            if uid==0:
                self.assertEqual(command[command.index('--cap-add')+1],'CAP_SETPCAP')
                self.assertEqual(payload[:4],['/usr/bin/python3','-I','-B','-c'])
                self.assertEqual(payload[4],namespace['ROOT_PAYLOAD_LAUNCHER'])
                self.assertEqual(payload[5:],['/usr/bin/true'])
            else:
                self.assertNotIn('--cap-add',command)
                self.assertEqual(payload,['/usr/bin/true'])
    def test_unchanged_namespaces_fail_before_engine(self):
        (self.bin/'bwrap').write_text(FAKE.replace("'fixture-child-'","'fixture-parent-'"))
        p,terminal=self.action('build');self.assertEqual(p.returncode,1);self.assertIn('namespace did not change',terminal['error'])
        self.assertFalse((self.root/'Output/process.pid').exists())
    def test_retained_capabilities_fail_before_engine(self):
        for key in ('CapInh','CapPrm','CapEff','CapBnd','CapAmb'):
            with self.subTest(capability=key):
                (self.bin/'bwrap').write_text(FAKE.replace(repr(key)+":'0'",repr(key)+":'1'"))
                p,terminal=self.action('build');self.assertEqual(p.returncode,1);self.assertIn('retained capabilities',terminal['error']);self.assertIn(key,terminal['error'])
                self.assertFalse((self.root/'Output/process.pid').exists())
    def test_new_privileges_fail_before_engine(self):
        (self.bin/'bwrap').write_text(FAKE.replace("'NoNewPrivs':'1'","'NoNewPrivs':'0'"))
        p,terminal=self.action('build');self.assertEqual(p.returncode,1);self.assertIn('could gain privileges',terminal['error'])
        self.assertFalse((self.root/'Output/process.pid').exists())
if __name__=='__main__':unittest.main(verbosity=2)
