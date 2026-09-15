"""Export synthetic demo evidence, never the App database or credential store."""
import argparse
import hashlib
import json
import pathlib
import sqlite3

p = argparse.ArgumentParser()
p.add_argument('container',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
p.add_argument('--source-sha',required=True)
a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
con=sqlite3.connect(a.container/'Library/Application Support/FloeAgent/floe.sqlite')
con.row_factory=sqlite3.Row
assert con.execute("SELECT secret_ref_synchronizable FROM providers WHERE id='D1730000-0000-4000-8000-000000000001'").fetchone()[0] == 0, 'Demo credential must not sync'
# The current runtime persists tool lifecycle in its append-only event stream;
# tool_calls is a legacy table and can be empty after a successful real call.
events=[dict(x) for x in con.execute("SELECT run_id,sequence,kind,payload_json FROM run_events WHERE kind IN ('toolRequest','toolResult','status','error') ORDER BY run_id,sequence")]
rows=[]
for event in events:
    payload=json.loads(event.pop('payload_json'))
    if event['kind']=='toolRequest':
        payload={key:payload.get(key) for key in ('tool','id','status')}
    event['payload']=payload
    if event['kind']=='toolResult':
        rows.append({'tool_name':payload.get('tool'), 'status':payload.get('status'),
                     'output_summary':payload.get('summary'), 'callID':payload.get('id')})
runs=[dict(x) for x in con.execute('SELECT id,state,started_at,ended_at FROM runs ORDER BY started_at')]
usage=[dict(x) for x in con.execute('SELECT input_tokens,output_tokens,cache_read_tokens,reasoning_tokens,is_estimated,total_duration_ms FROM run_usage ORDER BY recorded_at')]
errors=[dict(x) for x in con.execute('SELECT kind,message,http_status,recoverable FROM run_errors ORDER BY recorded_at')]
files=[x for x in a.container.rglob('review-demo.md') if x.is_file()]
valid=[x for x in files if 'FLOE-LIVE-173' in x.read_text(errors='replace') and 'Floe Agent Demo' in x.read_text(errors='replace')]
summary={'appSourceSHA':a.source_sha,'provider':'Volcengine Ark','remoteModelID':'deepseek-v4-1-flash-260910',
         'mode':'real remote model through ordinary Floe Agent','tools':rows,'matchingOutputs':len(valid),
         'usageCheckpoints':usage,'runErrors':errors,'runs':runs,'lifecycleEvents':events,
         'notPhysicalDeviceAcceptance':True,'generatedVideoSeconds':0}
if valid:
    data=valid[0].read_bytes(); (a.output/'review-demo.md').write_bytes(data)
    summary['markdownSHA256']=hashlib.sha256(data).hexdigest()
(a.output/'live-agent-evidence.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
assert valid, 'No verified Markdown output from the real Agent'
for name in ['workspace.createFile','workspace.readFile']:
    assert any(x['tool_name']==name and x['status']=='ok' for x in rows), f'No successful {name}'
assert runs and runs[-1]['state']=='completed', 'Real Agent did not reach successful completion'
print('Real Agent produced and read back the Markdown document.')
