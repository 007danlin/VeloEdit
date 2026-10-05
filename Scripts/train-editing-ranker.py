#!/usr/bin/env python3
"""Fit a small L2-regularized pairwise logistic model, using development data only.

Labels express technical dominance on measured chronology, repeated ranges,
action/speech boundaries and invalid ranges. They are NOT human taste labels.
The existing total editorial score is never used as a target.
"""
import argparse
import hashlib
import json
import math
import pathlib


FEATURES = ['chronologyErrors','repeatedSourceShare','incompleteActionShare','incompleteSpeechShare',
            'invalidRangeShare','shortShotShare','longShotShare','durationVariation','sourceCoverage',
            'meanSourceQuality','speechEvidenceShare']


def fit(rows, iterations=2000, rate=0.2, regularization=0.02):
    # Use every available comparison. Taking only the first N pairs per
    # project discarded later production variants whenever a small project
    # supplied only a few counterfactuals. Equal total mass per project keeps
    # a large tournament from overwhelming smaller projects without doing so.
    counts = {}
    for row in rows:
        counts[row['project']] = counts.get(row['project'], 0) + 1
    pair_weights = [1 / (len(counts) * counts[row['project']]) for row in rows]
    weights = [0.0]*len(FEATURES)
    for _ in range(iterations):
        gradient = [regularization*w for w in weights]
        for row, pair_weight in zip(rows, pair_weights):
            delta = [a-b for a,b in zip(row['preferred'],row['other'])]
            margin = sum(a*b for a,b in zip(weights,delta))
            residual = 1/(1+math.exp(max(-60,min(60,margin))))
            for i,x in enumerate(delta):
                # Automatic defect labels do not supervise taste, coverage or
                # pacing. Freeze those weights rather than learning incidental
                # correlations (e.g. a repeated shot's slightly higher quality).
                if i < 5: gradient[i] -= pair_weight*residual*x
        weights = [w-rate*g for w,g in zip(weights,gradient)]
    return weights


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dataset',type=pathlib.Path,required=True)
    p.add_argument('--split',type=pathlib.Path,required=True)
    p.add_argument('--output',type=pathlib.Path,required=True)
    args=p.parse_args()
    raw=args.dataset.read_bytes(); data=json.loads(raw);split=json.loads(args.split.read_text())
    assert data['featureNames']==FEATURES
    feature_schema=data.get('featureSchemaVersion',1)
    assert feature_schema in (1,2), 'Unknown feature semantics'
    rows=data['pairs']
    assert rows, 'No verified preferences: do not emit a pretend trained model'
    assert all(row['project'] in split['development'] for row in rows), 'Holdout contamination refused'
    assert all(row['labelProvenance']=='automatic-technical-dominance' for row in rows)
    assert all(len(row[key])==len(FEATURES) and all(math.isfinite(x) for x in row[key])
               for row in rows for key in ['preferred','other'])
    # Each project's total contribution is equal; no comparison is discarded.
    groups={n:[r for r in rows if r['project']==n] for n in sorted({r['project'] for r in rows})}
    weights=fit(rows)
    digest=hashlib.sha256(raw).hexdigest()
    model=dict(schemaVersion=feature_schema,modelID=f'technical-pairwise-balanced-features{feature_schema}-'+digest[:12],featureNames=FEATURES,
               weights=weights,trainingDataSHA256=digest,labelProvenance='automatic-technical-dominance',
               validatedForDefault=False)
    margins=[sum(w*(a-b) for w,a,b in zip(weights,r['preferred'],r['other'])) for r in rows]
    legacy_margins=[r['legacyPreferredScore']-r['legacyOtherScore'] for r in rows]
    metrics=dict(featureSchemaVersion=feature_schema,trainingPairs=len(rows),availablePairs=len(rows),projects=list(groups),
                 fittedPairAccuracy=sum(x>1e-6 for x in margins)/len(margins),
                 allDevelopmentPairAccuracy=sum(x>1e-6 for x in margins)/len(margins),
                 legacyGlobalScorePairAccuracy=sum(x>1e-6 for x in legacy_margins)/len(legacy_margins),
                 meanDevelopmentMargin=sum(margins)/len(margins),iterations=2000,learningRate=0.2,
                 l2=0.02,algorithm='deterministic full-batch project-balanced pairwise logistic regression',
                 balancing='All comparisons retained; each project has equal total objective weight',
                 projectPairCounts={str(n):len(group) for n,group in groups.items()},
                 evaluation='development pairs only, including fitted examples; NOT independent generalization or artistic quality',
                 humanLabels=0,implicitEditLabels=0,automaticLabels=len(rows),
                 availableHumanPreferences=len(data.get('availableHumanPreferences',[])),
                 trainedFeatures=FEATURES[:5],frozenFeatures=FEATURES[5:],
                 defaultEnabled=False,splitSHA256=hashlib.sha256(args.split.read_bytes()).hexdigest())
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'model.json').write_text(json.dumps(model,indent=2))
    (args.output/'training-metrics.json').write_text(json.dumps(metrics,indent=2))
    print(json.dumps(metrics,indent=2))


if __name__=='__main__':
    main()
