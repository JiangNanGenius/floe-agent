"""Seed only non-secret provider metadata in a disposable qualification App."""
import argparse
import datetime
import pathlib
import sqlite3

parser = argparse.ArgumentParser()
parser.add_argument('container', type=pathlib.Path)
args = parser.parse_args()
db = args.container / 'Library/Application Support/FloeAgent/floe.sqlite'
assert db.is_file(), 'The real App must initialize its database first'
provider = 'D1730000-0000-4000-8000-000000000001'
model = 'D1730000-0000-4000-8000-000000000002'
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
with sqlite3.connect(db) as con:
    con.execute('PRAGMA foreign_keys=ON')
    con.execute('''INSERT INTO providers (id,kind,wire_protocol,base_url,display_name,secret_ref_account,
        secret_ref_synchronizable,non_secret_headers_json,is_enabled,allows_plain_http,tool_name_compatibility,
        created_at,updated_at,sync_revision) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        (provider,'volcengineArk','openai-chat-completions','https://ark.cn-beijing.volces.com/api/v3',
         'Volcengine Ark Demo','provider.'+provider,0,'{}',1,0,1,now,now,0))
    con.execute('''INSERT INTO models (id,provider_id,remote_model_id,display_name,context_tokens,
        max_output_tokens,capabilities,reasoning_effort,is_enabled,is_hidden_from_primary_picker,use_surfaces)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)''',
        (model,provider,'deepseek-v4-1-flash-260910','DeepSeek V4.1 Flash',65536,2048,37,'low',1,0,5))
    con.execute('''UPDATE model_preferences SET onboarding_status='completed',default_agent_model_id=?,
        general_auxiliary_llm_model_id=?,updated_at=? WHERE id='default' ''', (model,model,now))
    assert con.execute("SELECT default_agent_model_id FROM model_preferences WHERE id='default'").fetchone() == (model,)
print('Disposable App metadata configured; no credential body was written to SQLite.')
