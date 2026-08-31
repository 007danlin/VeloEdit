# PROFESSIONAL EDITING KNOWLEDGE AUDIT — VeloEdit

Дата аудита: 24 августа 2026  
Объект: текущая production-ветка VeloEdit  
Формат работы: анализ исходного кода, моделей данных, pipeline, UI и тестов; код приложения не изменялся.

## 1. Краткий вывод

VeloEdit уже значительно сильнее обычного генератора хайлайтов. В production-пути есть proxy-first анализ, мультимодальные кандидаты, группировка событий, до 10 полноценных вариантов монтажа, global/pairwise selection, типизированные режиссёрские операции, transactional rollback, отдельный perceptual review готовой последовательности, проверка отрендеренных кадров, магнитная primary storyline, connected audio, FCPXML и осторожное обучение Personal Taste.

Главный разрыв с профессиональным монтажом находится не в количестве функций, а в **иерархии решений и качестве смысловых сигналов**:

1. Emotion и Story заявлены, но в финальном выборе размыты большим количеством почти равноправных технических метрик.
2. Система хорошо умеет выбрать и сохранить «пик», но ещё не понимает мысль, реакцию и причину склейки на уровне режиссёра.
3. Continuity в основном выводится из движения рамки объекта, композиционной оценки и общего semantic similarity; eyeline, ось сцены, shot size/angle и match-on-action по фазе движения отсутствуют или заменены грубыми прокси.
4. Ритм задаётся средними длительностями по роли, а не завершением мысли, движением внимания и вопросом «лучше ли CUT, чем HOLD».
5. Музыкальная структура измеряется содержательно, но scorers всё ещё поощряют совпадение почти каждой склейки с акцентом. Это легко превращает фильм в клип, подчинённый сетке, даже когда история требует тишины или выдержанного плана.
6. Архитектура позволяет J/L-cuts и sound bridges вручную, но автономный монтаж их почти не создаёт.

Итоговая оценка: **сильная инженерная база и хорошая автоматическая защита от технического брака; профессиональное режиссёрское мышление — PARTIAL, а для emotion/story/cut timing/continuity требуется пересборка objective layer, а не добавление ещё одной общей метрики.**

## 2. Что было изучено

### Заданные материалы

- Walter Murch, *In the Blink of an Eye*, весь предоставленный PDF, 81 страница.
- ТЗ из `ТЗ 9.docx`, включая перечень обязательных компонентов VeloEdit и требование остановиться после отчёта.
- Every Frame a Painting, [How Does an Editor Think and Feel?](https://vimeo.com/166319350).
- StudioBinder, [6 Ways to Edit Any Scene](https://www.youtube.com/watch?v=FVR8zz8ci2k), а также материалы о [continuity editing](https://www.studiobinder.com/blog/what-is-continuity-editing-in-film/), [match on action](https://www.studiobinder.com/blog/what-is-a-match-on-action-cut/) и [монтажных переходах](https://www.studiobinder.com/blog/types-of-editing-transitions-in-film/).
- Sven Pape / This Guy Edits: [официальный обзор канала](https://svenpape.com/index.php/portfolio/youtube/) и [описание подхода](https://thisguyedits.com/about/).
- Ripple Training / Steve Martin / Mark Spencer: [официальный сайт](https://www.rippletraining.com/blog/) и [FCP 12 Deep Dive](https://www.youtube.com/watch?v=soIqczyU02w).
- Apple Final Cut Pro: [Magnetic Timeline](https://support.apple.com/en-au/guide/final-cut-pro/verb8fcfc133/mac), [Roles](https://support.apple.com/guide/final-cut-pro/intro-to-roles-verb71cbcbe/mac), [Keywords](https://support.apple.com/en-mide/guide/final-cut-pro/ver68416335/mac), [поиск клипов](https://support.apple.com/en-is/guide/final-cut-pro/ver65764b45/mac), [object tracking](https://support.apple.com/guide/final-cut-pro/how-does-object-tracking-work-vere9b794f29/mac), [background rendering](https://support.apple.com/en-gb/guide/final-cut-pro/ver717f3ca3/mac), [Media Management](https://www.apple.com/final-cut-pro/docs/Media_Management.pdf).
- Jenn Jager, [официальные видео](https://jennjager.com/videos/).
- Matthew O’Brien, [editing workflow](https://www.youtube.com/watch?v=X4qkhxvNu-Q).
- Указанные в ТЗ материалы Dylan Bates / The Final Cut Bro.

### Основные принципы, принятые как критерии

Из Murch принципиальны четыре идеи:

- «делать максимум минимальными средствами» и уметь **не резать**; больше склеек не означает лучший монтаж;
- Rule of Six: Emotion 51%, Story 23%, Rhythm 10%, Eye-trace 7%, 2D plane 5%, 3D space 4%; при конфликте жертвовать снизу вверх, а не наоборот;
- склейка похожа на пунктуацию мысли: она должна попадать в момент изменения мысли/внимания, не опережать и не запаздывать;
- зрительский отклик важнее производственного происхождения кадра; технически несовершенный дубль может быть правильным, если в нём живёт нужная эмоция.

Проценты Murch не следует буквально копировать как универсальные ML-веса. Их правильное инженерное прочтение — **иерархическая оптимизация**: emotion/story задают допустимую область решения, rhythm выбирает момент, а continuity помогает выбрать между уже равноценными по смыслу вариантами.

### Ограничение аудита

Это source-level и architecture-level аудит, а не слепое исследование восприятия на репрезентативной видеоколлекции. Статус `IMPLEMENTED` означает, что принцип реально проходит через production-path и защищён кодом/тестом; он не означает доказанное равенство качеству работы опытного монтажёра. Для подтверждения perceptual quality нужен отдельный benchmark с экспертными парами и зрительскими тестами.

## 3. Легенда статусов

| Статус | Значение |
|---|---|
| `IMPLEMENTED` | Сигнал и действие реально влияют на production timeline; есть осмысленная защита/валидация. |
| `PARTIAL` | Полезная архитектура и часть evidence есть, но профессиональный смысл покрыт не полностью. |
| `WEAK` | Название/скоринг есть, но сигнал слишком груб, вес неверен или результат легко выглядит любительским. |
| `MISSING` | Нет production-модели/алгоритма, способного принять это решение автоматически. |

## 4. Матрица профессиональных принципов

| Принцип | Статус | Что есть сейчас | Главный разрыв |
|---|---|---|---|
| Cut only when the cut improves the moment | `WEAK` | Проверка высокой cut density и overlong clips | Нет явной альтернативы `HOLD`; система строит последовательность из выбранных фрагментов и редко доказывает необходимость каждой склейки |
| Emotion first | `WEAK` | `emotion`, people/audio-event proxies, emotional curve | Emotion часто бинарна: непустая строка/люди; в global score имеет малый и дублирующийся вес |
| Story advances with each edit | `PARTIAL` | scene summary, storyValue, event hierarchy, story roles | Story arc в основном равен наличию ролей и положению climax, а не причинно-следственной информации |
| Rhythm follows thought and attention | `WEAK` | pacing, mean shot duration, variation, breathing shots | Длительность в основном выводится из роли и глобального pacing, не из завершения мысли/взгляда/действия |
| Eye-trace | `WEAK` | subject bounding boxes, screen position, movement | Нет карты зрительского внимания и предсказания точки фиксации на выходе/входе |
| 2D screen plane / stage line | `WEAK` | знак `movementX` и близость позиции объекта | Нет scene axis, facing direction, camera side и осознанного нарушения оси |
| 3D spatial continuity | `WEAK` | event/scene grouping, GPS и semantic bridge | Нет географии сцены, относительных позиций героев/камер и coverage graph |
| Anticipation → action → peak → completion → reaction | `PARTIAL` | `MomentBoundary` и phase-aware trim сохраняют anticipation/peak/tail | Модель хранит только start/peak/end; action и reaction не имеют отдельных интервалов и доказательств |
| Не обрезать важный пик | `IMPLEMENTED` | `MomentPhaseTrimmer`, P6 incomplete-moment checks, rollback | Качество зависит от корректности одного activity peak |
| Реакция после события | `WEAK` | tail после peak называется completion/reaction; EventScenePhase содержит reaction | Reaction часто просто «первая группа после energy peak» либо outro-кандидат, а не выражение человека/пространства |
| Match on action | `WEAK` | сравнение среднего направления движения и completion | Нет сопоставления одной и той же фазы жеста/движения между планами |
| Screen direction | `PARTIAL` | dot product и знак движения объекта; P6 penalizes reversal | Не различается намеренная смена направления, движение камеры и движение героя; нет оси |
| Eyeline match | `MISSING` | face/person detection | Нет gaze/head pose, пары look/object и off-screen target |
| Shot-size progression / 30-degree logic | `WEAK` | площадь subject используется как proxy масштаба | Текущая continuity-функция награждает одинаковый масштаб, что может усиливать jump cuts |
| Establishing shot | `MISSING` | intro/atmosphere/scenic heuristics | Красивый широкий кадр не равен пространственно объясняющему establishing shot |
| Reaction/listener shot in dialogue | `MISSING` | speech phrase boundaries | Нет speaker/listener graph, diarization, facial response и subtext timing |
| Functional B-roll / cutaway | `PARTIAL` | connected overlays, unused stable/nature candidates, cutaway tool | B-roll выбирается по стабильности/атмосфере, а не по тому, какую информацию, jump или слабый участок он должен закрыть |
| Contrast and intellectual montage | `PARTIAL` | contrast/novelty variants, semantic diversity | Нет явной модели тезис → контртезис → новое значение; diversity может заменить смысл случайным отличием |
| Dialogue phrase integrity | `PARTIAL` | ASR boundaries, silence handles, P6 speech truncation findings | Нет семантической важности реплики, speaker turns и решения «показать слушателя раньше окончания фразы» |
| J-cuts, L-cuts, sound bridges | `MISSING` для auto / `IMPLEMENTED` вручную | `TimelineAudioClip`, detach/move/trim/fades/roles | Autonomous composer меняет attached volume и fades, но не планирует независимые пред-/построллы звука |
| Natural sound as story | `PARTIAL` | laughter/applause/impact/splash/speech, audio usefulness, ducking | Классификатор эвристический; нет room tone, ambience continuity и целевого sound bridge |
| Music structure, not only BPM | `PARTIAL` | measured onset/tempo/meter/downbeat/phrase/section/drop и confidence | Структурный анализ хорош, но selection всё ещё вознаграждает proximity почти каждой склейки к accent |
| Silence and cuts deliberately off-beat | `WEAK` | low-confidence beat-sync safety и quiet ranges | Нет позитивной модели intentional silence/off-beat; «не попасть в бит» обычно считается проигрышем |
| Motivated transitions | `WEAK` | effect review удаляет overload, low density defaults | `TimelineComposer` назначает transition по cadence; роль/жанр ещё заменяют конкретную причину перехода |
| Slow motion / ramps as emphasis | `PARTIAL` | frame-rate, action, stability, suitability, density, P6 | Мотивация выводится из action score; нет проверки, что retime раскрывает событие, а не украшает его |
| Titles/Motion/tracking/reframing | `PARTIAL` | editable title/effect objects, keyframes, subject-aware reframe, render inspection | Отдельные возможности сильны, но автономная стилистическая мотивация остаётся плотностной |
| Subject-aware reframe | `IMPLEMENTED` | tracking, visibility, lead room, safe edge, persisted/exported intent | Нет gaze/pose и устойчивой identity между разными планами |
| Event grouping across devices | `IMPLEMENTED` | time/GPS/visual/semantic/audio/filename/device offsets, hard splits | Группировка event сильнее, чем последующая интерпретация его драматургии |
| Multiple full variants and rollback | `IMPLEMENTED` | до 10 variants, distance gate, weak gate, pairwise tournament, Pareto, transactional repairs | Пользователь не видит осмысленные A/B alternatives; ошибочная objective-функция масштабируется на все варианты |
| Natural-language edit execution | `PARTIAL` | local LLM JSON schema + deterministic parser + typed tools + read-only advisory mode | Семантика «сделай честнее/держи реакцию/не режь мысль» не представлена типизированным editorial brief |
| Style detection from material | `PARTIAL` | project vector из action/people/atmosphere/aesthetic/speech/events | Emotion/style остаются агрегатами прокси; нет genre grammar, coverage и cinematographic intent |
| Personal Taste | `IMPLEMENTED` | gradual/contextual/decayed local learning, privacy, regression guard, bounded influence | Учится в основном на глобальных свойствах timeline; мало cut-level pairwise evidence |
| Optimal duration / no padding | `PARTIAL` | usable moments, confidence, material ceiling, learned duration | Unique grouping может оставить один момент на semantic event и недооценить полноценное coverage; average-shot prior остаётся сильным |
| Magnetic timeline and connected objects | `IMPLEMENTED` | primary storyline, connected overlays/audio, snapping, trimming, undo/redo, range AI brush | Нет ролей/keywords/range favorites как полноценного source-select workflow и waveform-level audio editing |
| Proxy-first responsive workflow | `IMPLEMENTED` | adaptive proxies, 4K playback proxies, caches, thermal scheduler, background preparation | Proxy policy технически зрелая; художественная проверка всё ещё ограничена sampled evidence |
| Versions / auditions | `PARTIAL` | checkpoints, undo/redo, persisted AI Edit versions | Альтернативы скрыты внутри tournament; нет compare/audition UI и явного выбора пользователя между 2–3 сильными решениями |
| Editable FCP handoff | `PARTIAL` | FCPXML primary clips, retime, audio, titles/metadata, rendered reference | Unsupported treatments требуют metadata/rendered fallback; roles/keywords/range selects используются не на уровне FCP workflow |

## 5. Аудит обязательных компонентов VeloEdit

### 5.1 AdaptiveAnalysis — `PARTIAL`

Сильные стороны:

- разреженная coarse sampling с dense проходом около visual/scene/telemetry peaks;
- длительность кандидата уже увеличивается для спокойного semantic material и уменьшается при движении;
- есть quota по interest, semantic potential и technical quality, VLM применяется к shortlist;
- после deep enrichment границы момента пересчитываются с audio/ASR/subject/VLM evidence.

Слабые стороны:

- dense sampling концентрируется вокруг визуальных peaks и активных сцен; тихая реакция после события может не стать отдельным кандидатом;
- базовый `interest` всё ещё на 27% состоит из motion, а первичный shortlist не резервирует establishing/listener/reaction/detail coverage;
- один привлекательный frame/short window может победить законченный, но менее энергичный эмоциональный момент.

Ключевые места: `AdaptiveAnalysis.swift:145-182`, `:673-759`, `:917-988`.

### 5.2 MomentBoundaryRefiner — `PARTIAL`

Сильная производственная идея: peak ищется локально, анализ идёт назад к anticipation и вперёд к completion, затем `MomentPhaseTrimmer` и P6 защищают диапазон от поздней обрезки. Это уже лучше фиксированного окна вокруг «лучшего кадра».

Проблема модели данных: `MomentBoundary` содержит только `anticipationStart`, `peakTime`, `completionEnd`. Поэтому комментарии и UI говорят «reaction», хотя система обычно знает лишь хвост падения activity. Нужны отдельные `actionStart`, `actionEnd`, `reactionStart`, `reactionEnd`, `holdUntil`, а также evidence/confidence по каждой фазе.

Ключевые места: `Models.swift:151-172`, `MomentBoundaryRefiner.swift:42-111`, `VariantQuality.swift:304-360`.

### 5.3 Event Grouping — `IMPLEMENTED` для событий, `WEAK` для сценической драматургии

`EventIntelligenceEngine` хорошо объединяет камеры по времени, GPS, embeddings, semantic/activity/people/audio evidence, именам файлов и оценённому clock offset. Есть hard splits, confidence и стабильные IDs.

Но `makeScenes` сначала группирует кандидаты, затем назначает `peak` группе с максимальной смесью action/quality; все группы до/после неё получают setup/preparation/action/reaction/conclusion преимущественно **по индексу**. Это структурная эвристика, а не распознавание реакции. Тест подтверждает воспроизводимость фаз, но не их семантическую истинность.

Ключевые места: `EventIntelligence.swift:41-247`, `:294-362`, `Models.swift:576-593`.

### 5.4 StoryEngine — `PARTIAL`

Сильные стороны:

- event-aware allocation, chronology, резерв одного момента на scene/phase;
- несколько реальных стратегий, distance gate и защита от близких вариантов;
- contextual ranking меняется от типа фильма, избранного материала и пользовательских anchors.

Слабые стороны:

- обычный selection разрешает только один candidate на `semanticEventID`; если кластер объединил setup/action/reaction одного события, coverage теряется;
- `rapidPeakReaction` выбирает «reaction» как лучший `.outro`;
- роли при fallback назначаются по позиции фильма, а не по содержанию;
- `storyArc` затем проверяет наличие этих же назначенных ролей — возникает self-confirming loop;
- внутри некоторых event strategies сортировка action/emotional utility идёт по возрастанию; даже если это задумано как build, правило не привязано к фазе и может поставить слабый эмоциональный кадр раньше без драматургической причины.

Ключевые места: `StoryEngine.swift:133-185`, `:598-685`, `:693-735`, `:786-918`.

### 5.5 TimelineComposer — `WEAK` как автономный монтажёр, сильный как renderer-ready assembler

Composer корректно соблюдает target duration, event/tag allocations, сохраняет moment range и создаёт редактируемые timeline objects. Однако adjacency почти не оптимизируется: кадры поступают в уже заданном порядке, после чего каждому назначается длительность по role/pacing.

Главная профессиональная ошибка — переходы назначаются периодически через `cadence = 1 / transitionDensity`. Вид перехода выбирается из media kind/action/preset. Это может быть визуально аккуратно, но художественно немотивированно.

Автоматическая звуковая режиссура отсутствует: музыка добавляется, attached original audio сохраняется на общем уровне, но независимые J/L-cuts и ambience bridges не создаются.

Ключевые места: `TimelineComposer.swift:63-114`, `:122-152`, `:155-175`.

### 5.6 AIDirectorEngine — `PARTIAL`

Сильные стороны:

- typed tools валидируют source ranges и структурные изменения;
- self-review запускает bounded beam из одиночных/парных repair calls;
- изменение принимается только при росте combined score и отсутствии safety violations;
- P6 рассматривает уже готовые shots/cuts и повторяет transactional commit;
- сохраняются speech phrases, useful natural sound, reframe, technical fixes и edit explanations.

Слабые стороны:

- self-review знает weak opening/climax, repeats, technical quality, average pacing, action share, transition density и role coverage, но не знает eyeline, establishing clarity, listener reaction, subtext, shot-size jump, intentional discontinuity и необходимость HOLD;
- climax равен преимущественно action + interest; «сильнейший action-момент» не обязательно эмоциональная кульминация;
- overlong определяется фиксированным maximum по role/pacing;
- B-roll overlay подбирается из `nature/atmosphere/stability`, а не из смысловой связи с конкретным base shot;
- переходы и эффекты всё ещё включаются deterministic density function.

Ключевые места: `AIDirectorEngine.swift:813-922`, `:926-1029`, `:1032-1219`, `:1230-1330`.

### 5.7 PerceptualReview — `PARTIAL`, но это важнейшая сильная основа

P6 — правильное архитектурное направление: cut-level scores отделены от global variant score; проверяются incomplete moments, speech/audio boundaries, motion reversal, repeated range, weak story, music fit, effects, overlays и реальные отрендеренные кадры. Repair имеет rollback.

Ограничения:

- `PerceptualScore` снова плоско смешивает 11 целей; story coherence весит 10%, music alignment — тоже 10%, technical integrity — 9%; Murch hierarchy не соблюдается;
- `compositionMatch` сравнивает scalar composition quality, а не точки внимания;
- `subjectContinuity` сравнивает broad kind, position и visibility, но не identity, gaze или axis;
- противоположное направление почти всегда считается ошибкой, хотя контраст/возвращение/осознанная смена оси могут быть правильными;
- story score снова основан на role coverage, peak near 78% и energy placement.

Ключевые места: `PerceptualReview.swift:97-170`, `:306-558`, `:567-687`, `:690-724`, `:896-1083`.

### 5.8 MontageVariantScoring / VariantQuality — `WEAK` objective, `IMPLEMENTED` search mechanics

Search mechanics зрелые: distance учитывает selection/source/semantic/order/rhythm; есть rejection records, weak gates, pairwise tournament, Pareto front и diagnostics.

Но winner выбирается неправильной иерархией. В `DefaultMontageGlobalScorer`:

- `storyArc` получает около 6% legacy total;
- отдельная `emotional` добавка — 4.5% base layer;
- `musicalAlignment`, `dropClimaxAlignment` и `musicStructureQuality` вместе могут весить больше, чем story/emotion;
- technical/semantic/source/diversity metrics дробят смысл на множество независимых голосов;
- для event story ещё 22% уходит в event aggregate.

Дополнительные ошибки continuity/rhythm:

- соседние clips одного `semanticEventID` получают `semanticBridge = 0.12`, хотя один event как раз часто обеспечивает пространственный мост;
- одинаковый размер объекта получает максимальный `shotScale`, что опасно для jump cuts;
- rhythm сравнивает клипы с фиксированными role durations (например, action 2.8, intro 6.8), а затем отдельно награждает variation;
- emotional curve считает наличие строки emotion/people/audio event, а не изменение состояния героя/зрителя.

Ключевые места: `MontageVariantScoring.swift:200-267`, `:390-419`, `:538-597`, `:631-699`, `:966-1206`; `VariantQuality.swift:176-290`.

### 5.9 MusicSyncEngine — `PARTIAL`

Сильная сторона: анализ не ограничен BPM — используются measured envelope/onsets, estimated meter, downbeats, phrases, sections, peaks, quiet ranges, drops и confidence. Есть cache и conservative fallback.

При этом `synchronize()` фактически привязывает к полубиту effects и titles, а не границы video clips. Video-to-music alignment происходит косвенно через variant scoring. Это безопаснее слепого ripple, но scorers оценивают почти все cuts по nearest accent и тем самым систематически предпочитают beat-heavy montage.

Нужна иерархия: story peak → phrase/section; несколько выбранных action accents → strong beat; остальные cuts свободны; тишина и off-beat могут быть положительным решением.

Ключевые места: `MusicSyncEngine.swift:89-207`, `MontageVariantScoring.swift:390-419`, `PerceptualReview.swift:639-670`.

### 5.10 Natural Language Director — `PARTIAL`

Local Director хорошо разделяет advisory/edit, использует строгую JSON schema, переводит результат в typed commands и имеет deterministic fallback. Это зрелая защита от ложных обещаний модели. Range AI brush ограничивает правку подсвеченным диапазоном.

Но natural-language слой знает в основном команды исполнения и несколько глобальных constraints. Для фраз «покажи реакцию раньше», «не режь мысль», «держи взгляд», «нарушь ось намеренно», «пусть звук приведёт в следующую сцену» нет соответствующих структурированных намерений. LLM может красиво объяснить решение, которое scorer не способен проверить.

Ключевые места: `DirectorConversation.swift:11-29`, `LocalDirectorAgent.swift:191-287`, `EditorCommandEngine.swift:151-643`.

### 5.11 Style Detection — `PARTIAL`

`AutonomousProjectStyleEngine` действительно смотрит на материал, а не просто переименовывает preset. Учитываются action, people, speech, atmosphere, aesthetics, audio, event variety и feature coverage. Это полезно.

Но emotion = непустая строка + people + laughter/applause/scream; cinematic = aesthetics + atmosphere + low action. Получаются удобные axes для настройки, но ещё не режиссёрская грамматика конкретного фильма. Нужны uncertainty, genre/scene-type, coverage sufficiency и narrative intent.

Ключевые места: `AutonomousDirector.swift:599-700`.

### 5.12 Personal Taste — `IMPLEMENTED`, с правильными safety constraints

Обучение локальное, приватное, контекстное, затухает во времени, требует повторных сигналов, допускает смену предпочтения и проходит regression guard. Влияние на variant selection ограничено confidence. Это профессионально безопаснее ручного «лайк/дизлайк» без контекста.

Следующий уровень — учиться не только среднему pacing/BPM/transitions, а pairwise предпочтениям на конкретных границах: CUT vs HOLD, reaction vs speaker, wide→close vs close→close, natural sound vs music.

Ключевые места: `AutonomousDirector.swift:144-220`, `:761-899`, `:901-994`; `AdaptiveTasteEngine.swift:511-625`, `:629-820`, `:858-923`.

### 5.13 Duration Preference — `PARTIAL`

`AutonomousDurationOptimizer` правильно ограничивает длительность usable material и не растягивает редкий материал до числа пользователя. Confidence снижает риск. Но strength/uniqueness всё ещё агрегированы на уровне candidate/event, а средняя длительность кадра выводится из style vector. Для длинной сцены с полноценным setup/action/reaction один semantic event может быть недооценён.

Ключевые места: `AutonomousDirector.swift:702-758`.

### 5.14 Preview / Timeline / media workflow — `IMPLEMENTED` технически, `PARTIAL` редакторски

Сильные стороны:

- одна magnetic primary storyline и независимые connected lanes;
- frame-accurate playhead, trim preview, drag/reorder, snapping, zoom, split, detach audio, undo/redo;
- отдельные audio/effect/title/telemetry lanes, editable transitions, local AI brush;
- 4K playback proxies, analysis proxies, thumbnails, cache reuse, thermal scheduling;
- favorites/excluded assets, checkpoints, FCPXML + rendered reference.

Недостаёт source-select привычек профессионального редактора:

- range favorites/rejects/keywords и named roles на уровне диапазона исходника;
- настоящих waveforms и явных J/L handles;
- skimmable selects/stringout view;
- A/B auditions лучших вариантов и cut alternatives;
- видимой причины AI-cut и возможности «показать соседние допустимые точки»;
- прямого сравнения current cut / previous cut / alternate cut без полной регенерации.

Ключевые места: `MontageTimelineView.swift:5-82`, `:291-371`, `:550-620`, `:681-757`, `:1014-1079`, `:1397-1450`; `VeloEditPipeline.swift:1776-1915`, `:1991-2023`, `:2081-2131`; `DerivedMedia.swift:68-216`; `FCPXMLExporter.swift:27-210`.

## 6. Где результат будет технически корректным, но непрофессиональным

1. **Правильный пик, неправильное чувство.** Самый энергичный action shot становится climax, хотя эмоциональная кульминация находится в реакции героя.
2. **Фальшивая реакция.** Первый более спокойный group после peak называется reaction, даже если это просто следующий пейзаж или другой момент.
3. **Монтаж без права на паузу.** Средняя длина соответствует preset, но важная мысль не успевает «сесть», потому что HOLD никогда не конкурировал с CUT.
4. **Jump cut, получивший высокий continuity score.** Одинаковая площадь одного субъекта и похожая композиционная оценка вознаграждаются, хотя угол и масштаб почти не изменились.
5. **Continuity без eyeline.** Движение слева направо совпало, но персонажи смотрят не друг на друга или ось разговора пересечена.
6. **Music-video syndrome.** Все cuts немного лучше совпадают с accents, поэтому вариант выигрывает у более живого монтажа с выдержанными паузами.
7. **Переход «по расписанию».** Cross dissolve появляется каждый N-й кадр, хотя между сценами нет изменения времени, памяти, состояния или пространства.
8. **B-roll как украшение.** Стабильный nature shot закрывает base clip, но не объясняет событие и не скрывает конкретный jump/weak performance.
9. **Технически чистый дубль вместо живого.** Self-review удаляет мягкий/недоэкспонированный кадр, потому что система не умеет доказать ценность исполнения.
10. **Сюжет по labels.** Timeline содержит intro/setup/climax/outro и получает высокий arc score, хотя между кадрами нет нового вопроса, ответа или причинной связи.
11. **«Эмоциональный» означает «есть люди».** People tag и непустая emotion string заменяют valence/arousal, изменение состояния и отношение зрителя к герою.
12. **Речь формально не обрезана, но сцена мертва.** Фраза сохранена целиком, однако камера всё время на говорящем; нет слушателя, реакции и subtext.
13. **Звук качает на каждой границе.** Attached audio получает короткие fades, музыка ducking, но отсутствие room-tone/sound bridge делает монтаж слышимо нарезанным.
14. **Speed ramp на подходящем action score.** Техника оправдана frame rate и стабильностью, но не подчёркивает нового смыслового момента.
15. **Красивый intro без ориентации.** Scenic/atmosphere shot выглядит дорого, но не объясняет где герои и куда направлено действие.

## 7. Предлагаемая целевая архитектура

### 7.1 Не ещё один score, а три уровня решения

**Hard safety / integrity**

- locked/excluded/source bounds;
- black/missing/frozen frames;
- complete speech unless intentional cut;
- no duplicate/repeated range;
- не удалять мотивированные treatments без эквивалентной замены;
- confidence-based abstention.

**Primary editorial objective**

- emotion of the moment;
- story information and causal progression;
- completeness of action/reaction;
- intended audience question/answer;
- `CUT` must beat `HOLD` by a calibrated margin.

**Secondary grammar / tie-breakers**

- rhythm and attention shift;
- eye-trace;
- 2D axis and screen direction;
- 3D geography;
- technical continuity;
- music alignment only at selected structural accents.

Нижний уровень может быть нарушен, если верхний выигрывает и нарушение осознанно записано в `EditorialDecisionReason`.

### 7.2 Новые модели данных

```swift
struct EditorialMomentEvidence {
    var anticipation: ClosedRange<Double>?
    var action: ClosedRange<Double>?
    var peak: ClosedRange<Double>
    var completion: ClosedRange<Double>?
    var reaction: ClosedRange<Double>?
    var doNotCutRanges: [ClosedRange<Double>]
    var preferredHoldUntil: Double?
    var confidenceByPhase: [MomentPhase: Double]
    var evidenceByPhase: [MomentPhase: [EvidenceID]]
}

struct ShotGrammarEvidence {
    var shotScale: ShotScale?
    var cameraAngle: CameraAngle?
    var subjectIdentities: [SubjectIdentity]
    var gazeVectors: [GazeVector]
    var facingDirections: [FacingDirection]
    var screenMotion: MotionVector?
    var cameraMotion: MotionVector?
    var sceneAxis: SceneAxis?
    var attentionPointAtIn: CGPoint?
    var attentionPointAtOut: CGPoint?
}

struct EditorialCutCandidate {
    var outgoing: ShotRange
    var incoming: ShotRange
    var cutTime: Double
    var emotionStoryRhythm: EditorialPrimaryScore
    var eyeTrace: Double
    var plane2D: Double
    var space3D: Double
    var intentionalDiscontinuity: EditorialIntent?
    var violations: [EditorialViolation]
    var alternativeHoldScore: Double
    var reason: EditorialDecisionReason
}
```

Дополнительно нужны:

- `SceneCoveragePlan`: establishing, master, action, detail, reaction, listener, cutaway, conclusion;
- `DialogueBeat`: speaker, listener, phrase, semantic importance, reaction opportunity, silence before/after;
- `AudioBridgeCandidate`: source event/ambience, usable pre-roll/post-roll, tail, room-tone compatibility;
- `MusicEditPoint`: beat/downbeat/phrase/section/drop с confidence и назначением, а не просто список accents;
- `EditorialIntent`: continuity, contrast, ellipsis, reveal, conceal, compression, emphasis, disorientation.

### 7.3 Новый порядок production pipeline

1. Существующий proxy-first анализ и event grouping.
2. Shot grammar extraction: scale/angle/identity/gaze/facing/camera motion/attention.
3. Stage-aware moment segmentation с отдельной reaction evidence.
4. Scene coverage graph и dialogue/audio beats.
5. Генерация не только shot candidates, но и **CUT/HOLD alternatives** на каждой границе.
6. Beam/DP sequence optimization по иерархическому objective, а не одной сумме.
7. Boundary refinement: thought/action/phrase/attention first, music second.
8. Audio plan: J/L, room tone, natural sound bridge, ducking, silence.
9. Selective transitions/retime/titles только при `EditorialIntent`.
10. Существующий P6 + rendered inspection, дополненный профессиональными findings.
11. Показ пользователю 2–3 действительно разных auditions и сбор pairwise taste evidence.

### 7.4 Скорость и стоимость

| Режим | Что считать | Стоимость |
|---|---|---|
| Fast | existing subject tracks, simple shot-scale bins, camera-vs-subject motion, speech/audio tails, CUT/HOLD, исправленный scorer | Низкая; в основном CPU и повторное использование cache |
| Balanced | face identity, head pose/gaze, optical-flow summaries, shot boundary scale/angle, speaker turns | Средняя; запуск только на candidate ranges и cut neighborhoods |
| Quality | VLM pairwise reasoning для top cut alternatives, reaction/subtext, deliberate discontinuity, expert-calibrated rerank | Высокая, но bounded: top-K cuts/variants, не все кадры |

Правила производительности:

- cache по content hash + model/schema version;
- сначала дешёвый exclusion/gate, затем дорогой rerank;
- VLM оценивает contact sheet «outgoing tail + incoming head + alternatives», а не одиночный кадр;
- low confidence не создаёт эффект/transition автоматически;
- рендерить только cut neighborhoods, titles/effects и сомнительные regions;
- сохранять diagnostics так, чтобы пользователь мог понять причину без повторного анализа.

## 8. Приоритетный план

### P0 — максимальный прирост восприятия без новых тяжёлых моделей

1. Заменить flat total на hierarchical Rule-of-Six selection.
2. Добавить `HOLD` как кандидата и `doNotCut`/`preferredHoldUntil` в существующий moment path.
3. Перестать называть весь post-peak tail реакцией; разделить `completion` и unknown reaction.
4. Переписать `storyArc` из role coverage в progression of information/intent; до новых моделей использовать scene summaries + event phases + speech + causal prompt evidence.
5. Исправить continuity: убрать безусловный штраф same-event, penalize near-identical same-subject scale/angle, различать camera и subject motion.
6. Удалить cadence-based automatic transitions; требовать `EditorialIntent` или явный user request.
7. Ограничить music scoring выбранными structural accents: intro phrase, selected action accents, climax/drop, outro phrase.
8. Создать автономный audio pass из уже имеющихся `TimelineAudioClip`: simple J/L, event tails, room-tone handles, music ducking.
9. Добавить P6 findings: `unnecessaryCut`, `jumpCutRisk`, `missingReaction`, `missingEstablishing`, `musicOvercut`.
10. Добавить regression fixtures, где технически лучший вариант эмоционально хуже, и где HOLD обязан победить CUT.

### P1 — новые лёгкие/средние evidence

1. Shot scale classifier и near-duplicate camera-angle estimate.
2. Face/subject identity между планами.
3. Head pose/gaze и базовый eyeline graph.
4. Optical-flow action-phase matching для match-on-action.
5. Scene coverage planner: establishing/master/detail/reaction/listener/cutaway.
6. Speaker turns и listener/reaction opportunities поверх ASR.
7. Attention points на in/out каждого candidate.
8. Реакции как отдельные кандидаты после audio/visual event peak.
9. Показ 2–3 variants/auditions в UI; pairwise выбор пользователя.
10. Range keywords/favorites/rejects и waveform/J-L handles в timeline/source browser.

### P2 — bounded semantic reasoning

1. VLM pairwise cut reviewer на top-K alternatives.
2. Emotion state model: valence/arousal/engagement/change, а не label presence.
3. Causal beat graph из scene summaries, transcript и event chronology.
4. Typed Natural Language intents для hold/reaction/eyeline/bridge/contrast/ellipsis.
5. Personal Taste на cut-level alternatives и контексте сцены.
6. Deliberate discontinuity model, чтобы continuity не превращалась в догму.
7. Music-to-story mapping на section/phrase уровне и intentional silence.

### P3 — доказательство качества и калибровка

1. Набор реальных проектов разных жанров и длительностей с разрешёнными материалами.
2. Expert annotations: moment phases, cut/hold, reaction, eyeline, axis, shot scale, story beat, audio bridge.
3. Pairwise «какой монтаж лучше и почему», а не абсолютная оценка 0–1.
4. Blind expert review и зрительские tests на emotion/comprehension/attention.
5. Метрики false-confidence: где система уверенно ошиблась.
6. Offline replay всего production pipeline для каждого scorer/model version.

## 9. Конкретные изменения по файлам и функциям

| Файл / функция | Что изменить | Приоритет |
|---|---|---|
| `Models.swift` — `MomentBoundary`, `CandidateInsights`, `StoryRole` | Добавить фазовый moment evidence, shot grammar, reaction/listener/establishing coverage; не маппить reaction в B-roll | P0–P1 |
| `MomentBoundaryRefiner.refine` | Возвращать отдельные phase ranges, hold windows и confidence; не выводить reaction только из спада activity | P0 |
| `AdaptiveAnalysis` candidate selection | Резервировать calm/reaction/establishing/listener/detail candidates; dense tail после сильного события | P0–P1 |
| `DeepMediaUnderstanding` subject/audio passes | Identity, gaze/head pose, camera-vs-subject flow, shot scale/angle, speaker turns, ambience/room tone | P1 |
| `EventIntelligence.makeScenes` | Определять phases по evidence; index/energy использовать как fallback с честным low confidence | P0–P1 |
| `StoryEngine.selectWithinEvent` | Использовать coverage plan и phase evidence; исправить strategy ordering; разрешить несколько функционально разных shots одного event | P0 |
| `StoryEngine.makeChapters` | Не назначать semantic role только по позиции; отделить display chapter от verified story beat | P0 |
| `TimelineComposer.compose` | Убрать cadence transitions; добавить adjacency optimizer и autonomous audio plan | P0 |
| `TimelineComposer.preferredDuration` | Duration от thought/action/attention evidence; role mean оставить prior, не target | P0 |
| `AIDirectorEngine.TimelineSelfReviewer` | Новые issues для unnecessary cut, missing coverage/reaction, jump cut, eyeline, music overcut | P0–P1 |
| `AIDirectorEngine.initialDecisions` | Эффекты/ramps/transitions только по explicit intent; B-roll по связи с base shot | P0 |
| `MontageVariantScoring.score` | Hierarchical objective и confidence; emotion/story не растворять в 20 метриках | P0 |
| `MontageVariantScoring.continuity` | Same-event context, identity, scale/angle change, gaze/axis, intentional contrast | P0–P1 |
| `MontageVariantScoring.rhythmQuality` | CUT vs HOLD, thought/action completion, local density curve, attention shift | P0 |
| `PerceptualMontageReviewer` | Сохранить отдельный P6, но ранжировать findings по Rule of Six; добавить render/contact-sheet pair review | P0–P2 |
| `MusicSyncEngine` / music scorers | Назначать ограниченное множество music edit points и поддерживать off-beat/silence | P0 |
| `EditorCommandEngine` / `LocalDirectorAgent` | Typed editorial intents и проверяемые scopes вместо одной текстовой normalized brief | P2 |
| `AutonomousProjectStyleEngine` | Calibrated emotion/style evidence, coverage sufficiency, explicit uncertainty | P1–P2 |
| `AdaptiveTasteEngine` | Pairwise cut-level signals; никогда не учить preference на rollback/accidental edit без подтверждения | P1 |
| `VeloEditPipeline.createFilm/regenerate` | Сохранять top auditions и их evidence, а не только winner diagnostics | P1 |
| `MontageTimelineView` | A/B auditions, waveforms, J/L handles, cut evidence, alternate edit points, source-range selects | P1 |
| `FCPXMLExporter` | Roles/keywords/range metadata и более полный editable audio handoff | P2 |

## 10. TOP 20 CHANGES — по влиянию на воспринимаемое качество

1. **Перевести финальный выбор на иерархию Emotion → Story → Rhythm → Eye-trace → 2D → 3D**, оставив технические параметры hard gates/tie-breakers.
2. **Добавить решение CUT vs HOLD** на каждой потенциальной границе; склейка должна доказать преимущество.
3. **Заменить role-coverage story score на causal/information beat graph**, чтобы labels не подтверждали сами себя.
4. **Ввести честную пятифазную модель момента**: anticipation, action, peak, completion, reaction + do-not-cut ranges.
5. **Создать SceneCoveragePlan** и резервировать establishing/action/detail/reaction/listener/cutaway по функции.
6. **Оптимизировать конкретные соседние пары и точки склейки**, а не только порядок готовых кандидатов.
7. **Автоматически строить J/L-cuts и natural-sound bridges** из уже существующей независимой audio architecture.
8. **Добавить gaze/eyeline/scene-axis evidence** и разрешать нарушение только с explicit intent.
9. **Добавить shot scale/angle grammar и jump-cut guard**; одинаковая площадь субъекта не должна автоматически повышать continuity.
10. **Синхронизировать с музыкой только выбранные structural moments**, а остальные cuts оставлять story-driven.
11. **Удалить cadence transitions** и требовать мотив: время, пространство, память, эллипсис, reveal, conceal или явный запрос.
12. **Выделять reaction candidates отдельным pass после сильных visual/audio events**, а не называть реакцией следующий group.
13. **Моделировать audience attention / eye-trace** на выходе и входе каждого плана.
14. **Выбирать B-roll относительно конкретной проблемы/информации base shot**, а не по общему nature/stability score.
15. **Добавить speaker/listener/subtext planning**: иногда резать на слушателя до конца реплики и держать реакцию после неё.
16. **Расширить P6 профессиональными findings** и ранжировать repair по perceptual impact, а не flat combined score.
17. **Показывать пользователю 2–3 осмысленные auditions** и учиться на pairwise выборе, сохраняя checkpoints.
18. **Перевести Personal Taste на cut-level context**, не ограничиваясь глобальными pacing/BPM/transitions.
19. **Добавить source-range workflow: keywords, favorites/rejects, roles, waveforms и J/L handles**, сохранив простоту magnetic timeline.
20. **Построить expert-annotated benchmark и blind perceptual evaluation**, иначе рост внутренних scores нельзя считать ростом профессионального качества.

## 11. Верификация текущего состояния

- Исходный код и ресурсы приложения не изменялись.
- Создан только этот аналитический отчёт.
- `swift test` был запущен на текущей базе: package успешно собрался, все выведенные test results завершились с `passed`. Полный параллельный прогон был остановлен вручную после длительного ожидания 302-asset production/scalability fixture; до остановки падений не было, поэтому это не подтверждает полный green run и не считается дефектом приложения.
- Полная пересборка `VeloEdit.app` не запускалась, потому что в соответствии с ТЗ код и ресурсы приложения не менялись.

## 12. Финальная рекомендация

Не начинать с новых эффектов, переходов или ещё одного «AI quality score». Самый короткий путь к заметно более профессиональному результату — P0-пакет: **иерархия Murch, CUT-vs-HOLD, честные phases/reaction, causal story, исправленная pair continuity, selective music и автономные sound bridges**. Эта работа использует уже построенную VeloEdit инфраструктуру и даёт больший perceptual gain, чем расширение каталога инструментов.
