#!/usr/bin/env python3
"""Host-only contracts, Mach-O fixtures and mocked compiler; no Native build."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import subprocess
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_compiled_lifecycle as lifecycle
import office_engine_repair as repair
import build_office_native_host as producer
import test_office_compiled_lifecycle as previous_tests

sha = lambda b: hashlib.sha256(b).hexdigest()

def macho(platform=2, cpu=0x100000c, tag=b'fixture'):
    return struct.pack('<8I', 0xfeedfacf, cpu, 0, 1, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, 0x1a0000, 0x1b0000, 0) + tag


def archive(path, members):
    value = b'!<arch>\n'
    for name, data in members:
        header = (name + '/').ljust(16) + '0'.ljust(12) + '0'.ljust(6) + '0'.ljust(6) + '644'.ljust(8) + str(len(data)).ljust(10) + '`\n'
        value += header.encode() + data + (b'\n' if len(data) % 2 else b'')
    path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(value)


class MultiSourceLifecycleTests(unittest.TestCase):
    def setUp(self):
        prior = previous_tests.MultiArchiveLifecycleTests('test_multi_archive_transport_pin_and_restore_are_exact')
        prior.setUp(); self.addCleanup(prior.doCleanups)
        self.prior = prior; self.f = f = prior.f
        p = f.base / 'patches/second.patch'; p.write_text('synthetic second-source patch')
        self.addition = {'sourceFile': 'engine/vcl/source/gdi/second.cxx',
            'originalSHA256': 'a'*64, 'patchedSHA256': 'b'*64,
            'patch': 'patches/second.patch', 'patchSHA256': sha(p.read_bytes()),
            'originalMemberSHA256': 'c'*64,
            'compileOverrides': {'flags': ['-DSECOND_IMPLEMENTATION'], 'sourceIncludes': ['engine/vcl/inc']}}
        for platform in ('IOS', 'IOSSIMULATOR'):
            f.lock['embeddedLifecycleOverlay']['compiledMembers'][platform]['additionalMembers'] = {'second.o': copy.deepcopy(self.addition)}
        self.spec = f.lock['embeddedLifecycleOverlay']['compiledMembers']['IOS']
        self.block = {**copy.deepcopy(prior.block), **lifecycle.identity(f.lock, 'IOS')}
        self.block.update(originalObjectSHA256ByMember={'svdata.o':'4'*64, 'second.o':'c'*64},
            objectABIByMember={n:{'arch':'arm64','platform':'IOS'} for n in ['svdata.o','second.o']},
            objectSHA256ByMember={'svdata.o':'8'*64,'second.o':'3'*64})
        self.block['linkOwnership']['archives']['libvcllo.a']['objectSHA256ByMember'] = copy.deepcopy(self.block['objectSHA256ByMember'])
        f.manifest['embeddedLifecycleMember'] = self.block
        prior.case.commit_contract()

    def test_v3_transport_pin_restore_exact_and_v2_cannot_masquerade(self):
        import bootstrap_office_host as bootstrap
        import pin_office_host_artifact as pinning
        f = self.f; original = f.pack(); f.validate(original)
        with patch.object(pinning,'HOST_SOURCES',f.base/'FloeOfficeNative'):
            self.assertEqual(pinning.apply(self.prior.case.lock_path,f.archive,'synthetic multi-source',
                                           artifact_run_id='9000000001',artifact_commit='a'*40),0)
        lock, pin = bootstrap.checked_lock(self.prior.case.lock_path)
        bootstrap.verify_installed(f.host, lock, pin)
        self.assertEqual(pin['embeddedLifecycleMember']['schemaVersion'],3)
        bad=copy.deepcopy(self.block); bad['schemaVersion']=2
        with self.assertRaises(ValueError): lifecycle.validate(bad,lock,'IOS')
        legacy={k:v for k,v in self.prior.case.block.items() if k not in ['schemaVersion','compiledPatchSHA256','sourceFile','originalSourceSHA256','patchedSourceSHA256','compilePassed','archiveReplacementPassed']}
        with self.assertRaisesRegex(ValueError,'historical compatibility'): lifecycle.validate_legacy_simulator(legacy,lock,{'libvcllo.a':'6'*64})

    def test_invalid_additional_member_and_source_contracts_fail_closed(self):
        for mutation in [
            lambda s:s['members'].update({'second.o':s['sourceFile']}),
            lambda s:s['additionalMembers']['second.o'].update(sourceFile=s['sourceFile']),
            lambda s:s['additionalMembers']['second.o'].pop('sourceFile'),
            lambda s:s['additionalMembers']['second.o'].update(originalMemberSHA256='wrong'),
            lambda s:s['additionalMembers']['second.o'].update(patch='../escape'),
            lambda s:s['additionalMembers']['second.o'].update(compileOverrides={'flags':['-xobjective-c++']}),
            lambda s:s['additionalMembers']['second.o'].update(compileOverrides={'flags':['@response']}),
            lambda s:s['additionalMembers']['second.o'].update(compileOverrides={'bundleIncludes':['../escape']}),
            lambda s:s['additionalMembers']['second.o'].update(members={'another.o':'engine/wrong.cxx'}),
        ]:
            lock=copy.deepcopy(self.f.lock); mutation(lock['embeddedLifecycleOverlay']['compiledMembers']['IOS'])
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):lifecycle.identity(lock,'IOS')
        (self.f.base/'patches/second.patch').write_text('tampered')
        with patch.object(producer.subprocess,'run') as run:
            with self.assertRaisesRegex(ValueError,'compiled patch bytes'):producer.select_lifecycle_archive(self.f.root,self.f.root/'unused','IOS',self.prior.case.lock_path,engine_source=self.f.root)
            run.assert_not_called()

    def test_wrong_original_selected_abi_source_and_link_hash_rejected(self):
        for mutate in [lambda b:b['originalObjectSHA256ByMember'].update({'second.o':'0'*64}),
            lambda b:b['objectABIByMember']['second.o'].update(platform='IOSSIMULATOR'),
            lambda b:b['memberSources']['second.o'].update(patchedSHA256='0'*64),
            lambda b:b['objectSHA256ByMember'].pop('second.o'),
            lambda b:b['linkOwnership']['archives']['libvcllo.a']['objectSHA256ByMember'].update({'second.o':'0'*64})]:
            bad=copy.deepcopy(self.block);mutate(bad)
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):lifecycle.validate(bad,self.f.lock,'IOS')

    def test_additional_archive_multisource_propagates_v3_without_downgrading_parent(self):
        lock=copy.deepcopy(self.f.lock);spec=lock['embeddedLifecycleOverlay']['compiledMembers']['IOS']
        added=spec.pop('additionalMembers');child_spec=spec['additionalArchives']['libsallo.a'];child_spec['additionalMembers']=added
        block=copy.deepcopy(self.block);block.update(lifecycle.identity(lock,'IOS'))
        block['objectSHA256ByMember']={'svdata.o':'8'*64};block['originalObjectSHA256ByMember']={'svdata.o':'4'*64};block['objectABIByMember']={'svdata.o':{'arch':'arm64','platform':'IOS'}}
        child=block['additionalArchives']['libsallo.a'];child.update(lifecycle.identity(lifecycle.single_lock(lock,'IOS',child_spec),'IOS'))
        child['objectSHA256ByMember'].update({'second.o':'3'*64});child['originalObjectSHA256ByMember']={'thread.o':'a'*64,'second.o':'c'*64};child['objectABIByMember']={n:{'arch':'arm64','platform':'IOS'} for n in child['members']}
        for name,b in {'libvcllo.a':block,'libsallo.a':child}.items():
            block['linkOwnership']['archives'][name]={'archiveSHA256':b['archiveSHA256'],'objectSHA256ByMember':copy.deepcopy(b['objectSHA256ByMember'])}
        child['linkOwnership']={**block['linkOwnership'],'archives':{'libsallo.a':copy.deepcopy(block['linkOwnership']['archives']['libsallo.a'])}}
        lifecycle.validate(block,lock,'IOS')
        self.assertEqual(block['schemaVersion'],3);self.assertEqual(child['schemaVersion'],3)

    def test_linkmap_requires_second_member_exact_owner_and_all_original_checks(self):
        prior=self.prior; prior.block=self.block; prior.child=self.block['additionalArchives']['libsallo.a']
        output,linkmap,linker,report,lines,inputs=prior.make_linkmap_fixture()
        producer.lifecycle_link_ownership(report,self.f.root,output,self.f.lock,'IOS',linker)
        line=next(l for l in lines if '(second.o)' in l)
        for changed in [[l for l in lines if l!=line],lines+[line], [l.replace('libvcllo.a(second.o)','other.a(second.o)') for l in lines]]:
            linkmap.write_text('\n'.join(changed))
            with self.assertRaisesRegex(ValueError,'absent/ambiguous'):producer.lifecycle_link_ownership(report,self.f.root,output,self.f.lock,'IOS',linker)

    def producer_fixture(self):
        f=self.f; root=f.root/'bundle-v3'; out=f.root/'producer-v3'; src=f.root/'source-v3'; src.mkdir(); out.mkdir()
        specs=lifecycle.member_specs(self.spec);members=[]
        for name,spec in specs.items():
            data=b'original-'+name.encode();p=src/spec['sourceFile'];p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
            spec['originalSHA256']=sha(data);spec['patchedSHA256']=sha(b'patched-'+data)
            payload=macho(tag=b'original-'+name.encode());members.append((name,payload))
            if name=='second.o':self.spec['additionalMembers'][name].update(spec,originalMemberSHA256=sha(payload))
            else:self.spec.update(originalSHA256=spec['originalSHA256'],patchedSHA256=spec['patchedSHA256'])
        members.append(('untouched.o',macho(tag=b'untouched')))
        ar=root/self.spec['archive'];archive(ar,members)
        (root/'prepared').mkdir();(root/'prepared/ios-all-static-libs.list').write_text(str(ar.resolve())+'\n')
        self.prior.case.lock_path.write_text(json.dumps(f.lock));repair_path=f.base/'engine.patch.lock.json';repair_path.write_text(json.dumps({'platforms':{'IOS':{'compile':{'sdk':'iphoneos','target':'arm64-apple-ios26.0','flags':[],'sourceIncludes':[],'bundleIncludes':[]}}}}))
        self.compiled=[];self.commands=[]
        def command(recipe,source,bundle,staged,obj):
            self.commands.append((copy.deepcopy(recipe),staged,obj));return ['mock-compiler',str(staged),str(obj)]
        def run(argv,**kw):
            argv=list(map(str,argv))
            if argv[0]=='git':
                staged=Path(kw['cwd'])/argv[2].split('=',1)[1];staged.write_bytes(b'patched-'+staged.read_bytes())
            elif argv[0]=='mock-compiler':
                staged,obj=map(Path,argv[1:]);self.compiled.append(staged);obj.write_bytes(macho(tag=staged.read_bytes()))
            elif argv[1:3]==['ar','-r']:
                existing=repair.read_ar_members(ar);payloads={p.name:p.read_bytes() for p in map(Path,argv[4:])};archive(Path(argv[3]),[(m.name,payloads.get(m.name,repair.read_member(ar,m))) for m in existing])
            return type('Done',(),{'returncode':0})()
        return root,out,src,command,run,ar

    def test_producer_compiles_each_real_source_and_preserves_unrelated_members(self):
        root,out,src,command,run,ar=self.producer_fixture()
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            block=producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual({p.name for p in self.compiled},{'svdata.cxx','second.cxx'})
        self.assertEqual(len(self.compiled),2)
        self.assertEqual(block['schemaVersion'],3)
        self.assertEqual(block['originalObjectSHA256ByMember']['second.o'],self.spec['additionalMembers']['second.o']['originalMemberSHA256'])
        self.assertEqual(set(block['objectABIByMember']),{'svdata.o','second.o'})
        extra=next(recipe for recipe,source,obj in self.commands if obj.name=='second.o')
        base=next(recipe for recipe,source,obj in self.commands if obj.name=='svdata.o')
        self.assertIn('-DSECOND_IMPLEMENTATION',extra['compile']['flags']);self.assertNotIn('-DSECOND_IMPLEMENTATION',base['compile']['flags'])

    def auxiliary_fixture(self, used=True):
        root,out,src,command,run,ar=self.producer_fixture()
        recipe=self.f.base/'engine.patch.lock.json';data=json.loads(recipe.read_text())
        data['platforms']['IOS']['compile']['auxiliaryIncludes']=['source/aux']
        recipe.write_text(json.dumps(data));aux=self.f.root/'aux';(aux/'source/aux').mkdir(parents=True)
        def with_dependencies(section,source,bundle,staged,obj,**kwargs):
            self.assertEqual(kwargs['aux_bundle'],aux.resolve())
            header=aux/'source/aux/header.h' if used else staged
            kwargs['depfile'].write_text('object: '+str(header)+'\n')
            return command(section,source,bundle,staged,obj)
        return root,out,src,with_dependencies,run,aux

    def test_auxiliary_headers_forwarded_verified_and_recorded_per_member(self):
        root,out,src,command,run,aux=self.auxiliary_fixture()
        closure=[{'path':'source/aux/header.h','sha256':'1'*64,'size':1}]
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command),patch.object(repair,'check_aux_bundle',return_value={'verified':True}) as check,patch.object(repair,'verify_auxiliary_closure',return_value=closure) as verify:
            block=producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec,aux_bundle=aux)
        self.assertEqual(check.call_count,1);self.assertEqual(verify.call_count,2)
        evidence=list((out/'lifecycle').rglob('*.compile-evidence.json'))
        self.assertEqual(len(evidence),2)
        self.assertTrue(all(json.loads(p.read_text())['auxiliaryHeaders']==closure for p in evidence))
        self.assertNotIn('auxiliaryInputEvidence',block)

    def test_unused_auxiliary_headers_record_empty_without_fabricated_closure(self):
        root,out,src,command,run,aux=self.auxiliary_fixture(used=False)
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command),patch.object(repair,'check_aux_bundle',return_value={'verified':True}),patch.object(repair,'verify_auxiliary_closure') as verify:
            producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec,aux_bundle=aux)
        verify.assert_not_called()
        self.assertTrue(all(json.loads(p.read_text())['auxiliaryHeaders']==[] for p in (out/'lifecycle').rglob('*.compile-evidence.json')))

    def test_changed_auxiliary_header_rejected_before_archive_replacement(self):
        root,out,src,command,run,aux=self.auxiliary_fixture();ar=root/self.spec['archive'];original=ar.read_bytes()
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command),patch.object(repair,'check_aux_bundle',return_value={'verified':True}),patch.object(repair,'verify_auxiliary_closure',side_effect=ValueError('header SHA differs')):
            with self.assertRaisesRegex(ValueError,'header SHA differs'):
                producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec,aux_bundle=aux)
        self.assertEqual(ar.read_bytes(),original)

    def test_unverified_auxiliary_input_rejected_before_compiler(self):
        root,out,src,command,run,aux=self.auxiliary_fixture()
        with patch.object(repair,'check_aux_bundle',side_effect=ValueError('bad auxiliary manifest')),patch.object(repair,'build_compile_command') as compiler:
            with self.assertRaisesRegex(ValueError,'bad auxiliary manifest'):
                producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec,aux_bundle=aux)
        compiler.assert_not_called()

    def test_member_auxiliary_override_isolated_from_other_member(self):
        root,out,src,command,run,aux=self.auxiliary_fixture()
        extra='source/engine/workdir/frozen/include'
        (aux/extra).mkdir(parents=True)
        self.spec['additionalMembers']['second.o']['compileOverrides']['auxiliaryIncludes']=[extra]
        recipe=self.f.base/'engine.patch.lock.json';data=json.loads(recipe.read_text())
        data['platforms']['IOS']['compile']['bundleIncludes']=[extra];recipe.write_text(json.dumps(data))
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command),patch.object(repair,'check_aux_bundle',return_value={'verified':True}),patch.object(repair,'verify_auxiliary_closure',return_value=[]):
            producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec,aux_bundle=aux)
        recipes={obj.name:recipe['compile'] for recipe,source,obj in self.commands}
        self.assertIn(extra,recipes['second.o']['auxiliaryIncludes'])
        self.assertNotIn(extra,recipes['svdata.o']['auxiliaryIncludes'])

    def test_officecfg_and_auxiliary_contracts_reject_unsafe_or_unknown_fields(self):
        valid={k:'1'*64 for k in ['schemaSHA256','stylesheetSHA256','dtdSHA256','generatedSHA256']}
        for component in ['../../evil','Office/UI/ToolbarMode/Extra','Office/x;evil','/Office','Office//Mode']:
            with self.subTest(component=component):
                spec=copy.deepcopy(self.spec);spec['compileOverrides']={'officecfgHeaders':{component:valid}}
                with self.assertRaises(ValueError):lifecycle.contract(self.f.lock,'IOS',spec=spec)
        for roots in [['/tmp/header'],['source/engine/../header'],['unverified/header']]:
            spec=copy.deepcopy(self.spec);spec['compileOverrides']={'auxiliaryIncludes':roots}
            with self.assertRaises(ValueError):lifecycle.contract(self.f.lock,'IOS',spec=spec)
        for value in [{**valid,'command':'bad'}, {k:v for k,v in valid.items() if k!='dtdSHA256'}, {**valid,'generatedSHA256':'not-a-hash'}]:
            spec=copy.deepcopy(self.spec);spec['compileOverrides']={'officecfgHeaders':{'Office/UI/Mode':value}}
            with self.assertRaises(ValueError):lifecycle.contract(self.f.lock,'IOS',spec=spec)

    def test_officecfg_output_hash_is_checked_before_compilation(self):
        from build_office_filter_overlay import generate_officecfg_headers
        stage=self.f.root/'generation';component='Office/UI/ToolbarMode'
        contract={component:{k:'1'*64 for k in ['schemaSHA256','stylesheetSHA256','dtdSHA256','generatedSHA256']}}
        def generate(source,output,components):
            p=output/('officecfg/'+component+'.hxx');p.parent.mkdir(parents=True);p.write_bytes(b'wrong')
            return []
        with patch.object(lifecycle,'source_bytes',return_value=b'input'),patch('build_office_filter_overlay.generate_officecfg_headers',side_effect=generate):
            with self.assertRaisesRegex(ValueError,'Generated officecfg header differs'):
                producer.prepare_lifecycle_officecfg(self.f.root,stage,contract,self.f.lock['commit'])

    def test_compile_must_consume_exact_declared_generated_header(self):
        for consume in [False,True]:
            with self.subTest(consume=consume):
                root,out,src,command,run,ar=self.producer_fixture()
                # producer_fixture uses a stable output path within this test; retain inputs while clearing only the previous owned result.
                if out.exists():
                    import shutil
                    shutil.rmtree(out)
                header=self.f.root/'generated/header.hxx';header.parent.mkdir(exist_ok=True);header.write_bytes(b'expected')
                generation={'headerSHA256':{str(header):sha(b'expected')},'commands':[],'inputSHA256':{}}
                self.spec['additionalMembers']['second.o']['compileOverrides']['officecfgHeaders']={'Office/Mode':{k:'1'*64 for k in ['schemaSHA256','stylesheetSHA256','dtdSHA256','generatedSHA256']}}
                def compile_command(recipe,source,bundle,staged,obj,**kwargs):
                    if kwargs.get('depfile'):
                        return ['generated-compiler','-c',str(staged),'-o',str(obj),'-MF',str(kwargs['depfile'])]
                    return command(recipe,source,bundle,staged,obj)
                def compile_run(argv,**kwargs):
                    if argv[0]=='generated-compiler':
                        obj=Path(argv[argv.index('-o')+1]);obj.write_bytes(macho(tag=b'generated'))
                        Path(argv[argv.index('-MF')+1]).write_text('object: '+(str(header) if consume else '/different/header.hxx')+'\n')
                        return type('Done',(),{'returncode':0})()
                    return run(argv,**kwargs)
                with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=compile_run),patch.object(repair,'build_compile_command',side_effect=compile_command),patch.object(producer,'prepare_lifecycle_officecfg',return_value=(header.parent,generation)):
                    if consume:
                        block=producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
                        self.assertIn('officecfgHeaders',block['memberSources']['second.o']['compileOverrides'])
                    else:
                        with self.assertRaisesRegex(ValueError,'Compile did not consume'):
                            producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
                # Only failed/successful owned compilation output is reused; reset fixture-owned input paths for the next subcase.
                if not consume:
                    import shutil
                    shutil.rmtree(root);shutil.rmtree(src);shutil.rmtree(out)

    def test_producer_rejects_wrong_original_member_before_any_compiler(self):
        root,out,src,command,run,ar=self.producer_fixture();self.spec['additionalMembers']['second.o']['originalMemberSHA256']='0'*64
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'original member hash'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual(self.compiled,[])

    def test_actual_object_abi_rejects_wrong_cpu_platform_or_missing_build_version(self):
        self.assertEqual(lifecycle.object_abi(macho(),'IOS'),{'arch':'arm64','platform':'IOS'})
        self.assertEqual(lifecycle.object_abi(macho(7),'IOSSIMULATOR'),{'arch':'arm64','platform':'IOSSIMULATOR'})
        for data in [macho(7),macho(cpu=7),b'not an object',macho()[:45],macho().replace(struct.pack('<I',0x32),struct.pack('<I',0x31),1)]:
            with self.subTest(data=data),self.assertRaises(ValueError):lifecycle.object_abi(data,'IOS')

    def test_missing_second_source_rejected_before_compiler(self):
        root,out,src,command,run,ar=self.producer_fixture()
        (src/self.addition['sourceFile']).unlink()
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'source checkout'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual(self.compiled,[])

    def test_wrong_second_source_hash_rejected_before_compiler(self):
        root,out,src,command,run,ar=self.producer_fixture()
        self.spec['additionalMembers']['second.o']['originalSHA256']='f'*64
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'source checkout'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual(self.compiled,[])

    def test_wrong_patched_source_hash_rejects_that_source_compilation(self):
        root,out,src,command,run,ar=self.producer_fixture()
        self.spec['additionalMembers']['second.o']['patchedSHA256']='f'*64
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'patched source differs'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertNotIn('second.cxx',[p.name for p in self.compiled])

    def test_wrong_compiled_abi_rejected_before_archive_replacement(self):
        root,out,src,command,run,ar=self.producer_fixture();original=ar.read_bytes()
        def wrong_abi(argv,**kw):
            result=run(argv,**kw)
            if argv[0]=='mock-compiler':Path(argv[-1]).write_bytes(macho(7))
            return result
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=wrong_abi),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'ABI platform'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual(ar.read_bytes(),original)

    def test_matching_hash_cannot_admit_wrong_platform_original_member(self):
        root,out,src,command,run,ar=self.producer_fixture();items=repair.read_ar_members(ar)
        wrong=macho(7,tag=b'wrong-original-platform')
        archive(ar,[(m.name,wrong if m.name=='second.o' else repair.read_member(ar,m)) for m in items])
        self.spec['additionalMembers']['second.o']['originalMemberSHA256']=sha(wrong)
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'ABI platform'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual(self.compiled,[])

    def test_duplicate_real_archive_members_rejected_before_compilation(self):
        root,out,src,command,run,ar=self.producer_fixture();items=repair.read_ar_members(ar)
        contents=[(m.name,repair.read_member(ar,m)) for m in items];archive(ar,contents+[contents[0]])
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'Duplicate lifecycle archive'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual(self.compiled,[])

    def test_unselected_duplicate_members_preserved_positionally(self):
        root,out,src,command,run,ar=self.producer_fixture();items=repair.read_ar_members(ar)
        contents=[(m.name,repair.read_member(ar,m)) for m in items]
        archive(ar,contents+[('untouched.o',b'second-distinct-payload')])
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=run),patch.object(repair,'build_compile_command',side_effect=command):
            block=producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        selected=out/'lifecycle'/ar.name/ar.name
        got=[repair.read_member(selected,m) for m in repair.read_ar_members(selected) if m.name=='untouched.o']
        self.assertEqual(got,[data for name,data in contents if name=='untouched.o']+[b'second-distinct-payload'])

    def test_changed_one_unselected_duplicate_rejected(self):
        root,out,src,command,run,ar=self.producer_fixture();items=repair.read_ar_members(ar)
        archive(ar,[(m.name,repair.read_member(ar,m)) for m in items]+[('untouched.o',b'distinct-last')])
        def tamper(argv,**kw):
            result=run(argv,**kw)
            if list(argv)[1:2]==['ranlib']:
                p=Path(argv[-1]);items=repair.read_ar_members(p)
                first=next(i for i,m in enumerate(items) if m.name=='untouched.o')
                archive(p,[(m.name,b'changed' if i==first else repair.read_member(p,m)) for i,m in enumerate(items)])
            return result
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=tamper),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'unexpected members'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)

    def test_archive_order_tampering_rejected_after_replacement(self):
        root,out,src,command,run,ar=self.producer_fixture();original=ar.read_bytes()
        def reorder(argv,**kw):
            result=run(argv,**kw)
            if list(argv)[1:2]==['ranlib']:
                p=Path(argv[-1]);items=repair.read_ar_members(p);archive(p,[(m.name,repair.read_member(p,m)) for m in reversed(items)])
            return result
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=reorder),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'order/count'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)
        self.assertEqual(ar.read_bytes(),original)

    def test_unrelated_member_tampering_rejected_after_replacement(self):
        root,out,src,command,run,ar=self.producer_fixture()
        def tamper(argv,**kw):
            result=run(argv,**kw)
            if list(argv)[1:2]==['ranlib']:
                p=Path(argv[-1]);items=repair.read_ar_members(p);archive(p,[(m.name,b'changed' if m.name=='untouched.o' else repair.read_member(p,m)) for m in items])
            return result
        with patch.object(producer.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'),patch.object(producer.subprocess,'run',side_effect=tamper),patch.object(repair,'build_compile_command',side_effect=command):
            with self.assertRaisesRegex(ValueError,'unexpected members'):producer._select_lifecycle_archive_single(root,out,'IOS',self.prior.case.lock_path,src,self.spec)

    def test_simulator_wrapper_keeps_additional_patch_and_requires_actual_source(self):
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'office_floe_simulator'))
        import build_simulator_framework as wrapper
        self.assertIn('patches/second.patch',wrapper.overlay_patch_refs(self.f.lock))
        source=self.f.root/'wrapper-source';(source/'.git').mkdir(parents=True)
        selected=self.f.lock['embeddedLifecycleOverlay']['compiledMembers']['IOSSIMULATOR']
        selected.pop('additionalArchives')
        p=source/selected['sourceFile'];p.parent.mkdir(parents=True);p.write_bytes(b'base source')
        selected['originalSHA256']=sha(p.read_bytes())
        self.prior.case.lock_path.write_text(json.dumps(self.f.lock))
        with patch.object(wrapper.subprocess,'check_output',return_value=self.f.lock['commit']+'\n'):
            with self.assertRaisesRegex(ValueError,'missing/modified lifecycle source: engine/vcl/source/gdi/second.cxx'):
                wrapper.validate_build_inputs(self.prior.case.lock_path,engine_source=source)

class LanguageOverrideContractTests(unittest.TestCase):
    """Bounded compile-language override (svxcore zero-motion dot member).

    The recorded vcl recipe compiles as `-x objective-c++`; the svxcore child
    was CI-compiled `-x c++` (the only byte-identity-proven substitution).
    `compileOverrides.language` expresses exactly that and nothing else: the
    contract bounds it to a pinned enum and compileOverrides.flags still only
    admits literal -D defines, so no arbitrary compiler-flag escape is possible.
    """
    def setUp(self):
        prior = MultiSourceLifecycleTests('test_producer_compiles_each_real_source_and_preserves_unrelated_members')
        prior.setUp(); self.addCleanup(prior.doCleanups)
        self.prior = prior; self.f = f = prior.f
        self.spec = f.lock['embeddedLifecycleOverlay']['compiledMembers']['IOS']
        self.base_overrides = copy.deepcopy(
            self.spec['additionalMembers']['second.o']['compileOverrides'])

    def overrides(self, **updates):
        value = copy.deepcopy(self.base_overrides)
        value.update(updates)
        return value

    def test_language_bounded_enum_and_unknown_or_typed_values_rejected(self):
        spec = copy.deepcopy(self.spec)
        spec['additionalMembers']['second.o']['compileOverrides'] = self.overrides(language='c++')
        lifecycle.contract(self.f.lock, 'IOS', spec=spec)
        for bad in ('objective-c++', 'c', 'assembler', '', 'c++ ', 'c++\t', 'C++'):
            spec['additionalMembers']['second.o']['compileOverrides'] = self.overrides(language=bad)
            with self.subTest(language=bad), self.assertRaises(ValueError):
                lifecycle.contract(self.f.lock, 'IOS', spec=spec)
        for bad in (123, ['c++'], {'lang': 'c++'}, True, None):
            spec['additionalMembers']['second.o']['compileOverrides'] = self.overrides(language=bad)
            with self.subTest(language=bad), self.assertRaises(ValueError):
                lifecycle.contract(self.f.lock, 'IOS', spec=spec)
        # Unknown override keys stay rejected alongside a valid language.
        value = self.overrides(language='c++')
        value['languageX'] = 'c++'
        spec['additionalMembers']['second.o']['compileOverrides'] = value
        with self.assertRaises(ValueError):
            lifecycle.contract(self.f.lock, 'IOS', spec=spec)
        # A -x escape attempt through flags stays rejected even with a valid
        # language present: the flags regex still only allows literal -D adds.
        value = self.overrides(language='c++', flags=['-DSVXCORE_DLLIMPLEMENTATION', '-xobjective-c++'])
        spec['additionalMembers']['second.o']['compileOverrides'] = value
        with self.assertRaises(ValueError):
            lifecycle.contract(self.f.lock, 'IOS', spec=spec)
        value = self.overrides(language='c++', flags=['-x', 'c'])
        spec['additionalMembers']['second.o']['compileOverrides'] = value
        with self.assertRaises(ValueError):
            lifecycle.contract(self.f.lock, 'IOS', spec=spec)

    def test_language_absent_keeps_recorded_objective_cxx_recipe(self):
        spec = copy.deepcopy(self.spec)
        lifecycle.contract(self.f.lock, 'IOS', spec=spec)
        receipts = lifecycle.member_specs(spec)
        self.assertNotIn('language', receipts['second.o']['compileOverrides'])

    def test_language_flows_to_member_specs_and_child_receipt(self):
        # Mirrors the real libsvxcorelo.a additionalArchive child: a fresh
        # single-member archive contract carrying the bounded language enum.
        child = {'sourceFile': 'engine/svx/source/svdraw/svdcrtv.cxx',
                 'originalSHA256': 'f' * 64, 'patchedSHA256': '8' * 64,
                 'archive': 'source/engine/instdir/program/libsvxcorelo.a',
                 'members': {'svdcrtv.o': 'engine/svx/source/svdraw/svdcrtv.cxx'},
                 'patch': 'patches/compiled.patch',
                 'patchSHA256': self.spec['patchSHA256'],
                 'compileOverrides': {'flags': ['-DSVXCORE_DLLIMPLEMENTATION'],
                                      'sourceIncludes': ['engine/svx/source/inc'],
                                      'language': 'c++'}}
        for platform in ('IOS', 'IOSSIMULATOR'):
            spec = copy.deepcopy(self.f.lock['embeddedLifecycleOverlay']['compiledMembers'][platform])
            spec['additionalArchives'] = {'libsvxcorelo.a': copy.deepcopy(child)}
            lifecycle.contract(self.f.lock, platform, spec=spec)
            receipts = lifecycle.member_specs(child)
            self.assertEqual(receipts['svdcrtv.o']['compileOverrides']['language'], 'c++')
            block = lifecycle.identity(lifecycle.single_lock(self.f.lock, platform, child), platform)
            self.assertEqual(block['compileOverrides']['language'], 'c++')
            self.assertEqual(block['compileOverrides']['flags'], ['-DSVXCORE_DLLIMPLEMENTATION'])

    def write_recorded_recipe(self, language_token='objective-c++'):
        """Give the fixture engine.patch.lock.json a realistic recorded vcl recipe."""
        recipe_path = self.f.base / 'engine.patch.lock.json'
        data = json.loads(recipe_path.read_text())
        flags = ['-std=c++20', '-O2', '-g0']
        if language_token is not None:
            flags += ['-x', language_token]
        data['platforms']['IOS']['compile']['flags'] = flags
        recipe_path.write_text(json.dumps(data))

    def test_producer_substitutes_recorded_language_for_overridden_member_only(self):
        root, out, src, command, run, ar = self.prior.producer_fixture()
        self.write_recorded_recipe()
        self.spec['additionalMembers']['second.o']['compileOverrides'] = self.overrides(language='c++')
        with patch.object(producer.subprocess, 'check_output', return_value=self.f.lock['commit'] + '\n'), \
             patch.object(producer.subprocess, 'run', side_effect=run), \
             patch.object(repair, 'build_compile_command', side_effect=command):
            producer._select_lifecycle_archive_single(root, out, 'IOS', self.prior.prior.case.lock_path,
                                                      src, self.spec)
        overridden = next(recipe for recipe, source, obj in self.prior.commands if obj.name == 'second.o')
        base = next(recipe for recipe, source, obj in self.prior.commands if obj.name == 'svdata.o')
        self.assertEqual({path.name for path in self.prior.compiled}, {'svdata.cxx', 'second.cxx'})
        flags = overridden['compile']['flags']
        self.assertEqual(flags.count('-x'), 1)
        self.assertEqual(flags[flags.index('-x') + 1], 'c++')
        self.assertIn('-DSECOND_IMPLEMENTATION', flags)
        base_flags = base['compile']['flags']
        self.assertEqual(base_flags.count('-x'), 1)
        self.assertEqual(base_flags[base_flags.index('-x') + 1], 'objective-c++')

    def test_producer_rejects_language_override_without_recorded_x_flag(self):
        root, out, src, command, run, ar = self.prior.producer_fixture()
        self.write_recorded_recipe(language_token=None)
        self.spec['additionalMembers']['second.o']['compileOverrides'] = self.overrides(language='c++')
        with patch.object(producer.subprocess, 'check_output', return_value=self.f.lock['commit'] + '\n'), \
             patch.object(producer.subprocess, 'run', side_effect=run), \
             patch.object(repair, 'build_compile_command', side_effect=command):
            with self.assertRaisesRegex(ValueError, 'exactly one recorded -x flag'):
                producer._select_lifecycle_archive_single(root, out, 'IOS', self.prior.prior.case.lock_path,
                                                          src, self.spec)
        self.assertNotIn('second.cxx', [p.name for p in self.prior.compiled])

    def test_producer_rejects_dangling_x_flag_with_language_override(self):
        root, out, src, command, run, ar = self.prior.producer_fixture()
        # Exactly one recorded -x, dangling at the end of the recipe; a child
        # archive (primary=False) adds no default flags, so nothing pads the
        # dangling token and the fail-closed branch is reachable.
        recipe_path = self.f.base / 'engine.patch.lock.json'
        data = json.loads(recipe_path.read_text())
        data['platforms']['IOS']['compile']['flags'] = ['-std=c++20', '-O2', '-g0', '-x']
        recipe_path.write_text(json.dumps(data))
        self.spec['additionalMembers']['second.o']['compileOverrides'] = self.overrides(language='c++', flags=[])
        with patch.object(producer.subprocess, 'check_output', return_value=self.f.lock['commit'] + '\n'), \
             patch.object(producer.subprocess, 'run', side_effect=run), \
             patch.object(repair, 'build_compile_command', side_effect=command):
            with self.assertRaisesRegex(ValueError, 'dangling -x flag'):
                producer._select_lifecycle_archive_single(root, out, 'IOS', self.prior.prior.case.lock_path,
                                                          src, self.spec, primary=False)
        self.assertNotIn('second.cxx', [p.name for p in self.prior.compiled])


class PinnedSourceFallbackTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.root=Path(temporary.name);self.name='engine/vcl/quartz/missing.cxx';self.path=self.root/self.name
        self.path.parent.mkdir(parents=True);self.data=b'pinned local Git source\n';self.path.write_bytes(self.data)
        def git(*args):return subprocess.check_output(['git','-C',str(self.root),*args],stderr=subprocess.PIPE)
        self.git=git;git('init','-q');git('add','.')
        git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','pinned fixture')
        self.commit=git('rev-parse','HEAD').decode().strip();self.spec={'sourceFile':self.name,'originalSHA256':sha(self.data)}
        git('update-index','--skip-worktree',self.name);self.path.unlink()

    def test_missing_sparse_file_reads_exact_local_object_without_materializing_checkout(self):
        before=self.git('status','--porcelain')
        self.assertEqual(lifecycle.source_bytes(self.root,self.spec,self.commit),self.data)
        self.assertFalse(self.path.exists());self.assertEqual(self.git('status','--porcelain'),before)
        staged=self.root/'owned-stage'/self.name;staged.parent.mkdir(parents=True);staged.write_bytes(lifecycle.source_bytes(self.root,self.spec,self.commit))
        self.assertEqual(staged.read_bytes(),self.data);self.assertFalse(self.path.exists())

    def test_changed_existing_source_is_rejected_without_falling_back(self):
        self.path.write_bytes(b'local change must survive')
        with patch.object(lifecycle.subprocess,'check_output') as read:
            with self.assertRaisesRegex(ValueError,'source hash differs'):lifecycle.source_bytes(self.root,self.spec,self.commit)
            read.assert_not_called()
        self.assertEqual(self.path.read_bytes(),b'local change must survive')

    def test_missing_blob_and_wrong_blob_hash_fail_without_fetch_or_new_files(self):
        for spec in [{**self.spec,'sourceFile':'engine/no-such-source.cxx'},{**self.spec,'originalSHA256':'0'*64}]:
            with self.subTest(spec=spec),self.assertRaises(ValueError):lifecycle.source_bytes(self.root,spec,self.commit)
        self.assertFalse(self.path.exists())

    def test_fallback_disables_lazy_fetch_and_interactive_authentication(self):
        actual=subprocess.check_output
        with patch.object(lifecycle.subprocess,'check_output',wraps=actual) as read:
            lifecycle.source_bytes(self.root,self.spec,self.commit)
        self.assertEqual(len(read.call_args_list),2)
        for call in read.call_args_list:
            self.assertEqual(call.kwargs['env']['GIT_NO_LAZY_FETCH'],'1')
            self.assertEqual(call.kwargs['env']['GIT_TERMINAL_PROMPT'],'0')
            self.assertTrue(call.args[0][-1].startswith(self.commit+':'))

if __name__=='__main__':unittest.main()
