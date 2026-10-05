import Foundation

/// Versioned starting style shipped identically in the app and CLI, in every
/// analysis mode. Contains aggregate editing parameters, never source media,
/// project IDs, embeddings, paths or reference fingerprints.
public enum BundledEditorialTaste {
    public static let version = "2026.10.01.1"
    public static let profile: PersonalTasteProfile = {
        // A checked, generated snapshot; decoding failure is a programming error.
        try! JSONDecoder.veloEdit.decode(PersonalTasteProfile.self, from: Data(snapshot.utf8))
    }()

    /// Decision-only view. Never feed this merged view back into the learner or
    /// persist it as the user's own evidence. A reset removes only local taste.
    public static func resolving(_ personal: PersonalTasteProfile) -> PersonalTasteProfile {
        var result = personal
        for (feature, estimate) in profile.preferences where result.preferences[feature] == nil {
            result.preferences[feature] = estimate
        }
        for (feature, estimate) in profile.adaptivePreferenceMap {
            // New local observations replace the starting prior for this
            // feature; the baseline's hundreds of samples never resist them.
            let legacyEntry = personal.preferences.filter { PersonalTasteProfile.canonicalAdaptiveFeature($0.key) == feature }
                .sorted { $0.key < $1.key }.max { $0.value.confidence < $1.value.confidence }
            let legacy = legacyEntry.map { entry in
                let value = entry.value
                return AdaptiveTasteEstimate(value: value.mean, confidence: value.confidence,
                    sampleCount: Int(value.evidenceWeight.rounded()), evidenceWeight: value.evidenceWeight, lastUpdated: value.updatedAt)
            }
            result.setAdaptiveEstimate(personal.adaptiveEstimate(for: feature) ?? legacy ?? estimate, for: feature)
        }
        var durations = personal.durationPreferences ?? TasteDurationPreferences()
        for feature in ["duration.film", "duration.action", "duration.calm", "duration.intro", "duration.climax", "duration.outro"] {
            if durations.estimate(for: feature) == nil, let value = profile.durationPreferences?.estimate(for: feature) {
                durations.set(value, for: feature)
            }
        }
        result.durationPreferences = durations
        let music = personal.musicTaste, baseMusic = profile.musicTaste
        result.musicTaste = MusicTasteProfile(
            preferredBPM: music?.preferredBPM ?? baseMusic?.preferredBPM,
            energy: music?.energy ?? baseMusic?.energy, beatSync: music?.beatSync ?? baseMusic?.beatSync,
            preferredTrackLength: music?.preferredTrackLength ?? baseMusic?.preferredTrackLength,
            preferredGenres: (baseMusic?.preferredGenres ?? [:]).merging(music?.preferredGenres ?? [:], uniquingKeysWith: { _, local in local }),
            preferredSections: (baseMusic?.preferredSections ?? [:]).merging(music?.preferredSections ?? [:], uniquingKeysWith: { _, local in local }),
            replacementCount: music?.replacementCount ?? 0)
        let titles = personal.titleTaste, baseTitles = profile.titleTaste
        result.titleTaste = TitleTasteProfile(size: titles?.size ?? baseTitles?.size,
            duration: titles?.duration ?? baseTitles?.duration,
            verticalPosition: titles?.verticalPosition ?? baseTitles?.verticalPosition,
            count: titles?.count ?? baseTitles?.count,
            animationIntensity: titles?.animationIntensity ?? baseTitles?.animationIntensity)
        // Existing confidence calculations normalize by evidence count. This
        // count is for this transient view only; diagnostics use the raw count.
        result.totalSignalCount = max(personal.totalSignalCount, profile.totalSignalCount)
        return result
    }

    private static let snapshot = #"""
{
  "calmMomentPreference": {
    "confidence": 0.7157751598142774,
    "evidenceWeight": 15.48019482160055,
    "lastUpdated": "2026-10-01T18:32:45Z",
    "negativeCount": 5,
    "neutralCount": 0,
    "positiveCount": 16,
    "sampleCount": 21,
    "value": 0.29874550682012563
  },
  "clipDurationPreference": {
    "confidence": 0.7311145211483818,
    "evidenceWeight": 16.43646260420537,
    "lastUpdated": "2026-09-14T18:07:51Z",
    "negativeCount": 10,
    "neutralCount": 0,
    "positiveCount": 13,
    "sampleCount": 23,
    "value": 0.07586551763961175
  },
  "colorPreference": {
    "confidence": 0.19242795544106073,
    "evidenceWeight": 1.32,
    "lastUpdated": "2026-09-15T07:40:37Z",
    "negativeCount": 0,
    "neutralCount": 0,
    "positiveCount": 2,
    "sampleCount": 2,
    "value": 0.72
  },
  "contextualPreferences": {},
  "durationPreferences": {
    "actionClipDuration": {
      "confidence": 0.3777072973544291,
      "evidenceWeight": 3.9945392196217826,
      "lastUpdated": "2026-09-14T18:07:51Z",
      "negativeCount": 6,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 6,
      "value": -0.5714273898075736
    },
    "calmClipDuration": {
      "confidence": 0.20889108392540479,
      "evidenceWeight": 1.4999276204082217,
      "lastUpdated": "2026-09-12T15:50:00Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 2,
      "sampleCount": 2,
      "value": 0.2499879373168212
    },
    "climaxDuration": {
      "confidence": 0.15193929950607998,
      "evidenceWeight": 0.92,
      "lastUpdated": "2026-09-05T13:37:55Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 1,
      "sampleCount": 1,
      "value": 1
    },
    "introDuration": {
      "confidence": 0.35998331583245613,
      "evidenceWeight": 3.669898506174925,
      "lastUpdated": "2026-09-05T13:35:15Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 4,
      "sampleCount": 4,
      "value": 0.8887879831427274
    },
    "outroDuration": {
      "confidence": 0.39756396387560755,
      "evidenceWeight": 4.378805772571963,
      "lastUpdated": "2026-09-05T15:29:35Z",
      "negativeCount": 1,
      "neutralCount": 0,
      "positiveCount": 4,
      "sampleCount": 5,
      "value": 0.6384663490133217
    },
    "preferredFilmDuration": {
      "confidence": 0.7446808917637275,
      "evidenceWeight": 17.343103585244044,
      "lastUpdated": "2026-10-01T18:32:44Z",
      "negativeCount": 12,
      "neutralCount": 2,
      "positiveCount": 14,
      "sampleCount": 28,
      "value": 0.15040380550229918
    }
  },
  "effectPreference": {
    "confidence": 0.7489455041737771,
    "evidenceWeight": 17.641004455422667,
    "lastUpdated": "2026-10-01T18:32:44Z",
    "negativeCount": 6,
    "neutralCount": 0,
    "positiveCount": 22,
    "sampleCount": 28,
    "value": 0.4530090278778407
  },
  "endingPreference": {
    "confidence": 0.9653727673169251,
    "evidenceWeight": 60.66269960883376,
    "lastUpdated": "2026-09-12T15:50:00Z",
    "negativeCount": 94,
    "neutralCount": 14,
    "positiveCount": 0,
    "sampleCount": 108,
    "value": -0.604547342589718
  },
  "musicSyncPreference": {
    "confidence": 0.5068293671670451,
    "evidenceWeight": 6.952020814924515,
    "lastUpdated": "2026-09-15T07:37:10Z",
    "negativeCount": 0,
    "neutralCount": 0,
    "positiveCount": 10,
    "sampleCount": 10,
    "value": 0.7151458445067397
  },
  "musicTaste": {
    "beatSync": {
      "confidence": 0.5068293671670451,
      "evidenceWeight": 6.952020814924515,
      "lastUpdated": "2026-09-15T07:37:10Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 10,
      "sampleCount": 10,
      "value": 0.7151458445067397
    },
    "energy": {
      "confidence": 0.14785621103378865,
      "evidenceWeight": 0.72,
      "lastUpdated": "2026-09-12T13:55:27Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 1,
      "value": 0.23999999999999996
    },
    "preferredBPM": {
      "confidence": 0.1665838837453547,
      "evidenceWeight": 0.82,
      "lastUpdated": "2026-09-10T15:46:15Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 1,
      "value": -0.2533069306930693
    },
    "preferredGenres": {
      "energetic": 0.78
    },
    "preferredSections": {
      "chorus": 0.32,
      "climax": 0.48,
      "drop": 0.48
    },
    "preferredTrackLength": {
      "confidence": 0.12092836525450112,
      "evidenceWeight": 0.58,
      "lastUpdated": "2026-09-12T13:55:27Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 1,
      "value": 0.3258426966292135
    },
    "replacementCount": 0
  },
  "preferences": {
    "calmMomentPreference": {
      "confidence": 0.967515109801195,
      "evidenceWeight": 15.421410966211608,
      "mean": 0.2846365765265384,
      "updatedAt": "2026-10-01T18:32:45Z"
    },
    "clipDurationPreference": {
      "confidence": 0.9622467052734414,
      "evidenceWeight": 14.745071383068748,
      "mean": -0.013324025326910216,
      "updatedAt": "2026-09-14T18:07:51Z"
    },
    "colorPreference": {
      "confidence": 0.25422098266547655,
      "evidenceWeight": 1.31996675733014,
      "mean": 0.48774778478130076,
      "updatedAt": "2026-09-15T07:40:37Z"
    },
    "cut.earlierExitPreference": {
      "confidence": 0.7899422604801811,
      "evidenceWeight": 7.021677761829643,
      "mean": 0.7343387023541545,
      "updatedAt": "2026-09-14T18:07:51Z"
    },
    "cut.energyContrastPreference": {
      "confidence": 0.24756784391069675,
      "evidenceWeight": 1.28,
      "mean": -0.5128489520430758,
      "updatedAt": "2026-08-31T15:27:10Z"
    },
    "cut.holdPreference": {
      "confidence": 0.7093739623561742,
      "evidenceWeight": 5.560730695167897,
      "mean": 0.7223423438865217,
      "updatedAt": "2026-09-14T18:07:51Z"
    },
    "cut.semanticBridgePreference": {
      "confidence": 0.26082621420431273,
      "evidenceWeight": 1.36,
      "mean": 0.495665878644602,
      "updatedAt": "2026-08-31T15:27:10Z"
    },
    "cut.shotScaleChangePreference": {
      "confidence": 0.2542264919086078,
      "evidenceWeight": 1.32,
      "mean": 0.0599183028752586,
      "updatedAt": "2026-08-31T15:27:10Z"
    },
    "duration.action": {
      "confidence": 0.5878997604259055,
      "evidenceWeight": 3.989198966796531,
      "mean": -0.5058451609821633,
      "updatedAt": "2026-09-14T18:07:51Z"
    },
    "duration.calm": {
      "confidence": 0.28345206261029166,
      "evidenceWeight": 1.4998955805525123,
      "mean": 0.1730822782931765,
      "updatedAt": "2026-09-12T15:50:00Z"
    },
    "duration.climax": {
      "confidence": 0.18489997600567198,
      "evidenceWeight": 0.92,
      "mean": 0.4339622641509434,
      "updatedAt": "2026-09-05T13:37:55Z"
    },
    "duration.film": {
      "confidence": 0.9770153798853565,
      "evidenceWeight": 16.97818489827292,
      "mean": 0.16998363811795922,
      "updatedAt": "2026-10-01T18:32:44Z"
    },
    "duration.intro": {
      "confidence": 0.5571577243340791,
      "evidenceWeight": 3.6654372414210896,
      "mean": 0.7498543164887419,
      "updatedAt": "2026-09-05T13:35:15Z"
    },
    "duration.outro": {
      "confidence": 0.6202633117013987,
      "evidenceWeight": 4.357247363890004,
      "mean": 0.5397105369714172,
      "updatedAt": "2026-09-05T15:29:35Z"
    },
    "duration.reaction": {
      "confidence": 0.558588380045185,
      "evidenceWeight": 3.6799985712594183,
      "mean": 0.7467427675189107,
      "updatedAt": "2026-08-26T09:26:01Z"
    },
    "effects": {
      "confidence": 0.9740097470347493,
      "evidenceWeight": 16.42515163739935,
      "mean": 0.4529836655653023,
      "updatedAt": "2026-10-01T18:32:44Z"
    },
    "endingPreference": {
      "confidence": 0.9999982563169791,
      "evidenceWeight": 59.66779951386958,
      "mean": -0.6242206881666728,
      "updatedAt": "2026-09-12T15:50:00Z"
    },
    "eventDuration": {
      "confidence": 0.40846540350681904,
      "evidenceWeight": 2.362657985334091,
      "mean": 0.25232198760154734,
      "updatedAt": "2026-08-26T09:26:01Z"
    },
    "musicBPM": {
      "confidence": 0.1665838837453547,
      "evidenceWeight": 0.82,
      "mean": -0.2533069306930693,
      "updatedAt": "2026-09-10T15:46:15Z"
    },
    "musicDuration": {
      "confidence": 0.12092836525450112,
      "evidenceWeight": 0.58,
      "mean": 0.3258426966292135,
      "updatedAt": "2026-09-12T13:55:27Z"
    },
    "musicEnergy": {
      "confidence": 0.14785621103378865,
      "evidenceWeight": 0.72,
      "mean": 0.23999999999999996,
      "updatedAt": "2026-09-12T13:55:27Z"
    },
    "musicGenre:energetic": {
      "confidence": 0.15914271763564924,
      "evidenceWeight": 0.78,
      "mean": 0.323030303030303,
      "updatedAt": "2026-09-12T13:55:27Z"
    },
    "musicIntensity": {
      "confidence": 0.6716778642801532,
      "evidenceWeight": 5.01192014159828,
      "mean": 0.5369437657438034,
      "updatedAt": "2026-09-15T07:37:10Z"
    },
    "musicSection:buildup": {
      "confidence": 0.9999464477544198,
      "evidenceWeight": 44.25683772455103,
      "mean": -0.3325939128762852,
      "updatedAt": "2026-09-15T07:37:10Z"
    },
    "musicSection:chorus": {
      "confidence": 0.09974951405229238,
      "evidenceWeight": 0.47287006497604334,
      "mean": 0.08720391117881313,
      "updatedAt": "2026-09-12T13:55:27Z"
    },
    "musicSection:climax": {
      "confidence": 0.5333786767801818,
      "evidenceWeight": 3.4300674958348636,
      "mean": -0.1520619546517434,
      "updatedAt": "2026-09-15T07:37:10Z"
    },
    "musicSection:drop": {
      "confidence": 0.09974951405229238,
      "evidenceWeight": 0.47287006497604334,
      "mean": 0.21723835643797362,
      "updatedAt": "2026-09-12T13:55:27Z"
    },
    "musicSection:intro": {
      "confidence": 0.8077629485788809,
      "evidenceWeight": 7.420617115563203,
      "mean": -0.4331674971334316,
      "updatedAt": "2026-09-15T07:37:10Z"
    },
    "musicSection:outro": {
      "confidence": 0.2722530960029097,
      "evidenceWeight": 1.430108777599325,
      "mean": -0.538733146609014,
      "updatedAt": "2026-09-15T07:36:57Z"
    },
    "musicSyncPreference": {
      "confidence": 0.7856636393108452,
      "evidenceWeight": 6.930939235457968,
      "mean": 0.6763013773640586,
      "updatedAt": "2026-09-15T07:37:10Z"
    },
    "reframing": {
      "confidence": 0.3681993038381267,
      "evidenceWeight": 2.066315799348516,
      "mean": 0.471174615097238,
      "updatedAt": "2026-09-15T07:27:34Z"
    },
    "shotDuration": {
      "confidence": 0.28163939112131686,
      "evidenceWeight": 1.4885261785641992,
      "mean": 0.607976179049731,
      "updatedAt": "2026-09-05T15:29:35Z"
    },
    "telemetry": {
      "confidence": 0.6253405178581917,
      "evidenceWeight": 4.417819709213519,
      "mean": 0.8202616661413886,
      "updatedAt": "2026-10-01T18:32:44Z"
    },
    "titleAnimation": {
      "confidence": 0.28345206261029166,
      "evidenceWeight": 1.4998955805525123,
      "mean": -0.692329113172706,
      "updatedAt": "2026-09-12T15:50:00Z"
    },
    "titleDuration": {
      "confidence": 0.5986729298442077,
      "evidenceWeight": 4.10840346522312,
      "mean": -0.2160509166829911,
      "updatedAt": "2026-09-14T17:18:19Z"
    },
    "titlePosition": {
      "confidence": 0.976730713981883,
      "evidenceWeight": 16.92279443089484,
      "mean": 0.03214591308241851,
      "updatedAt": "2026-09-29T12:24:07Z"
    },
    "titleSize": {
      "confidence": 0.9999395670076184,
      "evidenceWeight": 43.71288916801966,
      "mean": 0.011913857777595164,
      "updatedAt": "2026-09-29T12:24:51Z"
    },
    "titles": {
      "confidence": 0.8319826612366572,
      "evidenceWeight": 8.02659644090859,
      "mean": 0.04322704691245972,
      "updatedAt": "2026-09-15T07:55:59Z"
    },
    "transitionIntensity": {
      "confidence": 0.7840488574685528,
      "evidenceWeight": 6.8971638999027505,
      "mean": -0.2552555020369955,
      "updatedAt": "2026-10-01T18:32:44Z"
    },
    "visualDensity": {
      "confidence": 0.9248587065141567,
      "evidenceWeight": 11.647732610880054,
      "mean": 0.28347156793287964,
      "updatedAt": "2026-10-01T18:32:45Z"
    },
    "zoom": {
      "confidence": 0.1440604765877348,
      "evidenceWeight": 0.7,
      "mean": 0.28736842105263155,
      "updatedAt": "2026-09-15T07:27:34Z"
    }
  },
  "storyDensity": {
    "confidence": 0.6420846831045977,
    "evidenceWeight": 11.686260119295152,
    "lastUpdated": "2026-10-01T18:32:45Z",
    "negativeCount": 5,
    "neutralCount": 0,
    "positiveCount": 16,
    "sampleCount": 21,
    "value": 0.29502399505918797
  },
  "telemetryPreference": {
    "confidence": 0.401577718847384,
    "evidenceWeight": 4.459234144056366,
    "lastUpdated": "2026-10-01T18:32:44Z",
    "negativeCount": 0,
    "neutralCount": 0,
    "positiveCount": 6,
    "sampleCount": 6,
    "value": 0.8816383219409143
  },
  "titlePreference": {
    "confidence": 0.5447048594022897,
    "evidenceWeight": 8.066969440083188,
    "lastUpdated": "2026-09-15T07:55:59Z",
    "negativeCount": 6,
    "neutralCount": 0,
    "positiveCount": 6,
    "sampleCount": 12,
    "value": 0.0030592978302722167
  },
  "titleTaste": {
    "animationIntensity": {
      "confidence": 0.28345206261029166,
      "evidenceWeight": 1.4998955805525123,
      "lastUpdated": "2026-09-12T15:50:00Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 1,
      "value": -0.692329113172706
    },
    "count": {
      "confidence": 0.5447048594022897,
      "evidenceWeight": 8.066969440083188,
      "lastUpdated": "2026-09-15T07:55:59Z",
      "negativeCount": 6,
      "neutralCount": 0,
      "positiveCount": 6,
      "sampleCount": 12,
      "value": 0.0030592978302722167
    },
    "duration": {
      "confidence": 0.5986729298442077,
      "evidenceWeight": 4.10840346522312,
      "lastUpdated": "2026-09-14T17:18:19Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 4,
      "value": -0.2160509166829911
    },
    "size": {
      "confidence": 0.9999395670076184,
      "evidenceWeight": 43.71288916801966,
      "lastUpdated": "2026-09-29T12:24:51Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 44,
      "value": 0.011913857777595164
    },
    "verticalPosition": {
      "confidence": 0.976730713981883,
      "evidenceWeight": 16.92279443089484,
      "lastUpdated": "2026-09-29T12:24:07Z",
      "negativeCount": 0,
      "neutralCount": 0,
      "positiveCount": 0,
      "sampleCount": 17,
      "value": 0.03214591308241851
    }
  },
  "totalSignalCount": 793,
  "transitionPreference": {
    "confidence": 0.508062388832616,
    "evidenceWeight": 6.986237368040728,
    "lastUpdated": "2026-10-01T18:32:44Z",
    "negativeCount": 6,
    "neutralCount": 0,
    "positiveCount": 4,
    "sampleCount": 10,
    "value": -0.21527258867046573
  },
  "updatedAt": "2026-10-01T18:32:45Z"
}
"""#
}
