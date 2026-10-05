#!/usr/bin/env python3
"""Collect development-only technical preferences with auditable provenance."""
import argparse
import hashlib
import json
import pathlib


def safety(example):
    items=[i for i in example['timeline']['items'] if not i.get('overlay') and i['kind']!='title']
    values=example['features']['values']; count=max(1,len(items));duration=max(.05,sum(i['sourceDuration'] for i in items))
    return [values[0]*count,values[1]*duration,values[2]*count,values[3]*count,values[4]*count]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=pathlib.Path,required=True)
    p.add_argument('--side',default='development')
    p.add_argument('--evidence-map',type=pathlib.Path,
                   help='JSON mapping development project numbers to preserved run directories')
    p.add_argument('--output',type=pathlib.Path)
    p.add_argument('--require-all-development',action='store_true')
    args=p.parse_args();root=args.root.resolve()
    split=json.loads((root/'split.json').read_text());inventory=json.loads((root/'inventory.json').read_text())
    evidence_map={}
    if args.evidence_map:
        evidence_map={int(k):v for k,v in json.loads(args.evidence_map.read_text()).items()}
        assert set(evidence_map)<=set(split['development']), 'Holdout evidence mapping refused'
        assert all(isinstance(v,str) and pathlib.Path(v).name==v and v.startswith('development')
                   for v in evidence_map.values()), 'Only development run directories allowed'
    hashes=lambda ns:{a['quickHash'] for row in inventory['projects'] if row['number'] in ns for a in row['assets']}
    assert not hashes(split['development'])&hashes(split['holdout']), 'Source overlap across split'
    source_audit_path=root/'source-full-fingerprint-audit.json'
    source_audit=None
    if source_audit_path.exists():
        raw_audit=source_audit_path.read_bytes();audit=json.loads(raw_audit)
        assert audit['complete'] and audit['allStableDuringRead'], 'Full source fingerprint audit incomplete'
        assert audit['allInitialSizeAndMTimeMatch'], 'Sources changed from initial size/mtime snapshot'
        assert not audit['fullSHA256OverlapAcrossSplit'], 'Full-file source overlap across split'
        fingerprints=root/'source-full-fingerprints.jsonl'
        source_audit=dict(path=str(source_audit_path),sha256=hashlib.sha256(raw_audit).hexdigest(),
            fingerprintsPath=str(fingerprints),fingerprintsSHA256=hashlib.sha256(fingerprints.read_bytes()).hexdigest(),
            limitation=audit['limitation'])
    if args.require_all_development:
        assert source_audit is not None, 'Complete full-source fingerprint audit required for final dataset'
    pairs=[];inputs=[];feature_names=None;feature_schema=None
    for n in split['development']:
        side=evidence_map.get(n,args.side)
        directory=root/side
        run_path=directory/f'project-{n}-run.json'
        run=json.loads(run_path.read_text()) if run_path.is_file() else None
        if args.require_all_development:
            assert run and run['exitCode']==0 and run['outputExists'], f'Completed development export {n} required'
            verification=directory/f'project-{n}-verification/technical-report.json'
            assert verification.is_file() and json.loads(verification.read_text())['fullDecodeCompleted'], f'Full export verification {n} required'
            assert (directory/f'project-{n}-examples.json').is_file(), f'Final decision examples {n} required'
        files=[directory/f'project-{n}-examples.json']
        files+=sorted((directory/f'project-{n}-variants').glob('*.json'))
        for file in files:
            if not file.is_file():continue
            raw=file.read_bytes();data=json.loads(raw)
            version=data.get('schemaVersion',1)
            assert version in (1,2), 'Unknown feature schema'
            if feature_schema is not None:assert feature_schema==version, 'Mixed feature semantics refused; re-extract preserved timelines with one build'
            feature_schema=version
            if feature_names is not None:assert feature_names==data['featureNames']
            feature_names=data['featureNames']
            digest=hashlib.sha256(raw).hexdigest()
            inputs.append(dict(project=n,side=side,path=str(file),sha256=digest,
                runReceipt=str(run_path) if run else None,
                runReceiptSHA256=hashlib.sha256(run_path.read_bytes()).hexdigest() if run else None,
                cliSHA256=run.get('cliSHA256') if run else None))
            examples=data['examples']
            for i,preferred in enumerate(examples):
                a=safety(preferred)
                for j,other in enumerate(examples):
                    if i==j:continue
                    b=safety(other)
                    if all(x<=y+1e-6 for x,y in zip(a,b)) and any(x<y-1e-6 for x,y in zip(a,b)):
                        pairs.append(dict(project=n,preferred=preferred['features']['values'],other=other['features']['values'],
                            preferredName=preferred.get('name',preferred.get('strategy')),otherName=other.get('name',other.get('strategy')),
                            preferredSafety=a,otherSafety=b,labelProvenance='automatic-technical-dominance',
                            evidenceFile=str(file),evidenceSHA256=digest,preferredIndex=i,otherIndex=j,
                            legacyPreferredScore=preferred['legacyScore'],legacyOtherScore=other['legacyScore'],
                            limitation='Metadata clocks and detected boundaries are not human-confirmed event semantics; counterfactuals may be unrendered. No artistic label.'))
    human=[]
    if args.require_all_development:
        assert {row['project'] for row in inputs} == set(split['development']), 'Not all development projects have evidence yet'
    for file in sorted((root/'comparisons').glob('project-*-human-preference.json')):
        record=json.loads(file.read_text())
        assert record['project'] in split['development'], 'Holdout human label refused for training'
        human.append(dict(preference=record,path=str(file),sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
    output=args.output or root/'training';output.mkdir(parents=True,exist_ok=True)
    dataset=dict(schemaVersion=1,featureSchemaVersion=feature_schema,featureNames=feature_names,pairs=pairs,inputs=inputs,split=split,sourceAudit=source_audit,
                 evidenceMap={str(n):evidence_map.get(n,args.side) for n in split['development']},
                 humanLabels=0,availableHumanPreferences=human,implicitEditLabels=0,
                 humanLabelUse='Retained separately for artistic model development; this technical fit does not learn artistic taste from these sparse excerpt preferences.',
                 rule='Technical Pareto dominance only. No target based on engine global score. All counterfactuals retain provenance.')
    (output/'dataset.json').write_text(json.dumps(dataset,ensure_ascii=False,indent=2))
    print(json.dumps(dict(pairs=len(pairs),projects=sorted({r['project'] for r in pairs}),inputs=len(inputs))))


if __name__=='__main__':main()
