#!/usr/bin/env python3
"""Prepare reproducible, isolated editorial comparison inputs; never edits sources.
This manifest was prepared during implementation, so it is a development corpus,
not the preregistered independent acceptance set required by Q01.
"""
import hashlib, json, pathlib, shutil, uuid, urllib.parse, datetime, argparse
root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'Build/EditorialQuality/corpus'

def sha(path):
    with path.open('rb') as f:
        h=hashlib.sha256()
        for block in iter(lambda:f.read(1024*1024), b''):h.update(block)
    return h.hexdigest()

def read(relative):
    path=root/'Build'/relative/'project.json'
    return path,json.loads(path.read_text())

sources = {
 'short': 'AutonomyAcceptance-2026-09-13/exact.veloedit',
 'ride': 'AutonomyValidation/test5-dynamic/automatic.veloedit',
 'journey': 'AutonomyValidation/test6-release/automatic.veloedit',
 'people': 'DirectorAudit-test4/test4-audit.veloedit',
 'mixed': 'Checks/MixedMedia-2026-09-09-v2/Фото и видео — рыбалка.veloedit'
}
cases=[('01','short',15,'dynamic',False,None,False),('02','ride',30,'cinematic',True,6,False),
       ('03','people',60,'calm',False,None,False),('04','mixed',30,'calm',True,None,True),
       ('05','journey',300,'cinematic',False,None,False),('06','ride',120,'dynamic',False,None,False)]
for i in range(6): cases.append((f'{i+7:02}','journey',20 if i<3 else 60,['dynamic','calm','cinematic'][i%3],i%2==0,(i*6,(i+1)*6),i<3))
parser=argparse.ArgumentParser();parser.add_argument('--prepare',action='store_true');args=parser.parse_args()
if not args.prepare: parser.error('--prepare is required')
if (out/'manifest.json').exists(): raise SystemExit('Existing corpus preserved. Choose a separate corpus for a new comparison.')
out.mkdir(parents=True,exist_ok=True)
pool=out/'music';pool.mkdir(exist_ok=True)
tracks=[]; identities=set()
for relative in sources.values():
    path=root/'Build'/relative/'MusicLibrary/tracks.json'
    if not path.exists():continue
    for track in json.loads(path.read_text()):
        source=pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(track['localFileURL']).path))
        if not source.is_file():continue
        digest=sha(source)
        if digest in identities:continue
        identities.add(digest);dest=pool/(digest+source.suffix)
        if not dest.exists():shutil.copy2(source,dest)
        track['localFileURL']=dest.as_uri();tracks.append(track)
manifest={'createdAt':datetime.datetime.now().astimezone().isoformat(),'purpose':'development corpus; no human ratings collected',
 'preregisteredBeforeAlgorithmChanges':False,'independentAcceptanceSet':False,'musicFiles':[{ 'path':t['localFileURL'],'sha256':pathlib.Path(urllib.parse.urlparse(t['localFileURL']).path).stem } for t in tracks], 'cases':[]}
for case,key,seconds,mood,vertical,subset,fresh in cases:
    source,original=read(sources[key]);d=json.loads(json.dumps(original));assets=d['assets']
    if isinstance(subset,tuple):assets=assets[subset[0]:subset[1]]
    elif isinstance(subset,int):assets=assets[:subset]
    ids={a['id'] for a in assets};d['assets']=assets;d['analyses']=[] if fresh else [a for a in d['analyses'] if a['assetID'] in ids]
    d['id']=str(uuid.uuid4()).upper();d['name']='Editorial Quality '+case
    for field in ['timelines','storyPlans','events','renderJobs','timelineCheckpoints','preferenceSignals','musicCredits']:d[field]=[]
    for field in ['sourceMap','intentLedger','filmBuildRecovery','filmBuildContentRevision','autonomousJob','personalTasteProfile','editorialHumanEvaluation','removedMedia']:d.pop(field,None)
    d['preferences'].pop('chapterTitleReference',None)
    brief=dict(original.get('workspaceState',{}).get('directorBrief',{}));brief.update(requestedDuration=seconds,durationMode='exact',mood=mood,musicPolicy='match-video',sourceAudioPolicy='duck',titlePolicy='key-only')
    brief.pop('musicTrackID',None)
    brief['canvasFormat']={'width':1080 if vertical else 1920,'height':1920 if vertical else 1080,'label':'9:16' if vertical else '16:9','subjectAware':True,'safeAreasEnabled':True}
    brief['canvasFormatIsAutomatic']=False
    # Inspectable prompts are shared verbatim by both builds.
    prompt=f'Сделай фильм ровно {seconds} секунд. Настроение: '+{'dynamic':'динамичное','calm':'спокойное','cinematic':'киношное'}[mood]+f'. Формат: {"9:16" if vertical else "16:9"}. Музыка: подобрать под видео. Приглушить звук исходников до 20%. Титры: названия частей.'
    d['workspaceState']=dict(prompt=prompt,preset='adventure',directorBrief=brief,targetMinutes=seconds/60,hasPendingFilmChanges=False,feedbackDraft='',directorDraft='',directorMessages=[],pendingDirectorInstructions=[])
    caseDir=out/case;caseDir.mkdir(exist_ok=True)
    for version in ('before','after'):
        package=caseDir/(version+'.veloedit');package.mkdir(exist_ok=True)
        (package/'MusicLibrary').mkdir(exist_ok=True)
        (package/'MusicLibrary/tracks.json').write_text(json.dumps(tracks,ensure_ascii=False))
        (package/'project.json').write_text(json.dumps(d,ensure_ascii=False))
    manifest['cases'].append(dict(id=case,source=str(source),sourceManifestSHA256=sha(source),assetIDs=sorted(ids),sourceContentHashes=[a['contentHash'] for a in assets],mood=mood,seconds=seconds,format='9:16' if vertical else '16:9',freshAnalysis=fresh,prompt=prompt,inputTimelineCount=0,status='prepared-not-run',humanRatings=[]))
(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
print('Prepared',len(cases),'pairs;',len(tracks),'local music files;',sum(c[-1] for c in cases),'fresh analysis cases')
