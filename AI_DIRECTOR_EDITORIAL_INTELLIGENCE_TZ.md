# Техническое задание: Editorial Intelligence для AI Director

Статус: проект технического задания  
Дата: 2026-09-06  
Область: исключительно логика и модели `VeloEditCore`; без новых кнопок, экранов, ручных переключателей и обязательных действий пользователя

## 1. Резюме

Нужно переработать автоматический монтаж VeloEdit так, чтобы его главным результатом был не формально заполненный Timeline, а фильм, который выдерживает обычный человеческий просмотр без желания проматывать повторяющиеся или бессодержательные участки.

Текущий pipeline уже умеет анализировать видео, строить события, находить кандидаты, выбирать стиль, создавать несколько вариантов, подбирать музыку, делать subject-aware reframe и запускать self-review. Проблема находится не в отсутствии отдельных возможностей, а в приоритетах принятия решений:

- длительность и формальное покрытие материала иногда оказываются важнее редакционной плотности;
- семантически похожие планы могут пройти как разные кандидаты;
- одинаковые планы объединяются в длинные последовательные блоки по исходному файлу;
- Story Role может быть назначена формально, без реального изменения состояния истории;
- средний итоговый score способен скрыть один критический провал;
- source-space анализ не всегда обнаруживает проблему, появившуюся после вертикального crop и финального compositing;
- автоматические звук, эффекты, telemetry и титры могут противоречить пользовательскому intent или содержанию сцены;
- repair loop умеет исправлять локальные дефекты, но не обязан перестроить слабую структуру целиком.

Новая версия должна ввести отдельный слой `Editorial Intelligence`, который оценивает не только качество каждого фрагмента, но и изменение зрительского опыта во времени: что нового получил зритель, изменилось ли действие, кто является героем, не повторяется ли визуальная ситуация, есть ли причина продолжать просмотр и завершена ли обещанная история.

## 2. Наблюдаемые дефекты, которые ТЗ обязано устранить

Требования ниже основаны на фактических текущих проектах. Идентификаторы конкретных проектов и клипов нельзя использовать в production-логике: они являются только регрессионными примерами.

### 2.1. Проект «Мой фильм»

Текущий результат:

- 33 primary-фрагмента;
- длительность 164,89 с;
- 31 из 33 фрагментов имеет длительность ровно 5 с;
- первые 40 с состоят из восьми похожих POV-планов движения за велосипедистом;
- материал сгруппирован крупными непрерывными блоками по исходным файлам: 8 + 8 + 8 + 9 фрагментов;
- присутствуют два подтверждённых соседних повтора source range;
- примерно с 65-й по 75-ю секунду используются слабые кадры, в которых сцену перекрывают человек крупным планом и столб;
- примерно с 80-й по 120-ю секунду значительную часть композиции занимает корпус транспортного средства;
- последние примерно 45 с состоят из почти одинаковых ракурсов водителя;
- отсутствует фактический intro; 17 фрагментов помечены как outro, хотя не выполняют функцию завершения;
- есть только один вступительный титр;
- telemetry G-force появляется десять раз, включая моменты без редакционно значимого изменения показателя;
- музыка `Western ShowDown` и футуристический HUD не образуют цельный язык со спокойной летней поездкой;
- последняя просьба о дополнительных титрах остаётся pending и не отражена в текущем фильме.

Ожидаемое улучшение: система должна предпочесть короткую, разнообразную и завершённую версию, а не сохранять большое количество однотипных моментов. При текущем наборе выбранных сцен допустимый результат ориентировочно находится в диапазоне 60–90 с, если новый анализ не обнаружит дополнительные события.

### 2.2. Проект «тест 3»

Текущий результат:

- 23 primary-фрагмента;
- длительность 289,44 с при запросе ровно 300 с;
- 0:00–1:33 — четыре длинных фрагмента одного рыболовного эпизода;
- 1:33–3:19 — около 106 с визуально похожих общих планов людей возле багги;
- 3:19–4:49 — четыре велосипедных плана длительностью 19–25 с;
- крупные блоки снова следуют порядку исходных файлов, а не внутренней драматургии;
- вертикальный crop в отдельных точках обрезает человека, оставляя технический объект в центре;
- в Timeline остался только титр «День 1 — Рыбалка», хотя позднее начинается другая активность;
- добавленная фотография `Yesterday.JPG` не использована и не получила объяснимого решения об исключении;
- около 3:29–3:39 применяются pixelate, halftone и cinematic stack без смысловой мотивации;
- пользовательский запрос убрать исходный звук нарушается: в начале существуют detached audio clips с громкостью 1,0, позднее — natural sound с громкостью 0,28;
- результат одновременно не достигает точных пяти минут и воспринимается искусственно растянутым.

Ожидаемое улучшение: 5-минутный фильм разрешается только при доказанном запасе разных событий и действий. Иначе система должна сначала расширить поиск сильных моментов, а при недостатке материала создать более короткий честный монтаж и явно зафиксировать, почему точная длительность несовместима с quality gates.

### 2.3. Проект «тест 2»

Текущий результат:

- исходники импортированы и проанализированы;
- пользовательский intent на создание фильма существует;
- Timeline отсутствует;
- карточка проекта показывает исходный thumbnail, который может восприниматься как превью готового фильма.

Ожидаемое улучшение мозга: незавершённая или устаревшая background-операция не должна оставлять проект в неопределённом состоянии. Pipeline обязан либо атомарно сохранить валидный Timeline, либо сохранить типизированную причину невозможности его создать и безопасно предложить повторный запуск через уже существующий conversation/status flow.

## 3. Цель продукта

После реализации пользователь должен получать фильм, для которого истинны следующие утверждения:

1. Каждый оставленный фрагмент добавляет новую информацию, эмоцию, действие, точку зрения или необходимую атмосферную паузу.
2. Два соседних фрагмента не повторяют одну и ту же визуальную ситуацию без осознанной причины.
3. Длительность является следствием количества сильного материала, а не причиной расширять слабые source ranges.
4. Начало быстро объясняет предмет фильма или создаёт сильный вопрос; финал отвечает на обещание начала либо осознанно завершает наблюдение.
5. Вертикальный и любой другой отличный от исходника формат сохраняет людей, лица, направление движения и смысл композиции.
6. Музыка, оригинальный звук, титры, эффекты и telemetry подчинены истории и пользовательскому intent.
7. Preview и export показывают одинаковые композиционные решения.
8. При низкой уверенности система ведёт себя консервативно: короче, проще, меньше эффектов, без рискованных crop и без выдуманного сюжета.

## 4. Ограничения области работ

### 4.1. Входит в работу

- модели данных и алгоритмы `VeloEditCore`;
- повторное использование существующего media analysis и его расширение;
- Story Engine, Autonomous Director, Timeline Composer;
- variant generation, global/pairwise scoring и hard quality gates;
- self-review, perceptual review и автоматический repair;
- subject tracking и reframe;
- автоматическая логика титров, звука, музыки, эффектов и telemetry;
- обработка pending intent, project revision и background generation;
- диагностика, кэширование, unit/integration/regression tests;
- согласованность preview/export.

### 4.2. Не входит в работу

- новые кнопки, панели, мастера, настройки и режимы;
- ручная разметка пользователем;
- обязательный A/B-выбор вариантов;
- облачный backend;
- изменение оригинальных медиафайлов;
- обучение на личных данных вне существующей privacy-safe модели Personal Taste;
- генерация отсутствующих событий с помощью synthetic video;
- маскировка плохого монтажа переходами, эффектами или агрессивной музыкой.

### 4.3. Требование к пользовательскому потоку

Существующий поток должен сохраниться:

`Import → Analyze → AI Edit / Regenerate → Preview → Export`.

Новая логика включается автоматически. Для сообщений о недостатке материала, нарушенном exact-duration или отклонённом новом asset используется существующий канал Director Conversation и status, без нового UI.

## 5. Основные принципы принятия решений

При конфликте целей применяется следующий порядок приоритетов:

1. Безопасность данных и целостность проекта.
2. Явный пользовательский запрет или обязательный content intent.
3. Отсутствие критических технических и композиционных дефектов.
4. Смысловая связность и завершённость.
5. Отсутствие повторов и достаточная редакционная плотность.
6. Сохранение целого действия, речи и реакции.
7. Качество кадра и звука.
8. Стиль, Personal Taste и музыкальная синхронизация.
9. Соответствие желательной длительности.

`durationFit`, количество использованных файлов и разнообразие эффектов не имеют права компенсировать провал пунктов 1–6.

## 6. Новые понятия Editorial Intelligence

### 6.1. Editorial Unit

`EditorialUnit` — минимальный кандидат, описывающий не только source range, но и происходящее внутри него.

Обязательные свойства:

- `sourceRange`;
- `eventID`, `sceneID`, `semanticEventID`;
- главный и второстепенные субъекты;
- действие в начале, середине и конце;
- `actionDelta`: насколько состояние изменилось за фрагмент;
- `visualDelta`: насколько меняются композиция, фон, масштаб и направление движения;
- `informationGain`: сколько новой информации момент добавляет относительно уже выбранной последовательности;
- `completion`: содержит ли момент anticipation, peak, completion/reaction;
- `entryQuality` и `exitQuality`;
- speech/audio-event boundaries;
- признаки окклюзии и crop risk;
- shot scale, camera angle, camera motion и camera mount;
- `shotFamilyID`;
- confidence и происхождение evidence.

### 6.2. Shot Family

`ShotFamily` объединяет визуально и редакционно взаимозаменяемые фрагменты. Одного semantic event недостаточно.

В сигнатуру должны входить:

- embedding сцены;
- тип и положение главного субъекта;
- крупность;
- camera angle;
- направление и величина движения;
- фон/локация;
- camera mount: handheld, static, body/helmet POV, vehicle-mounted, drone и т. п.;
- временная близость source ranges;
- устойчивые окклюзии и доминирующие объекты;
- тип действия.

Примеры одной семьи:

- серия POV-кадров следования за одним велосипедистом на одной дорожке;
- серия общих планов двух сидящих людей возле одного багги;
- последовательность близких кадров одного водителя с одной камеры;
- два пересекающихся диапазона одного source clip.

### 6.3. Narrative Beat

`NarrativeBeat` — проверяемая функция внутри фильма, а не строковая роль.

Beat обязан содержать:

- `purpose`: hook, orientation, setup, development, escalation, peak, reaction, transition, closure;
- утверждение о том, что зритель должен понять или почувствовать;
- требуемое изменение относительно предыдущего beat;
- допустимые event/scene/shot families;
- минимальное evidence;
- желательный диапазон длительности;
- критерий выполнения.

Назначить клипу `storyRole = climax` недостаточно. Climax засчитывается только при подтверждённом локальном максимуме действия, эмоции, аудиособытия или смыслового завершения.

### 6.4. Editorial Density

`EditorialDensity` измеряет полезное изменение за секунду фильма.

Она складывается из:

- semantic information gain;
- action/state change;
- появления нового субъекта или реакции;
- смены осмысленного масштаба/точки зрения;
- завершения начатого действия;
- полезного speech/audio event;
- подтверждённой атмосферной ценности.

Движение камеры само по себе не считается новым содержанием. Другая временная точка того же статичного setup также не считается новым содержанием.

### 6.5. Content Budget

`ContentBudget` хранит оценку того, сколько фильма реально поддерживает материал:

```swift
public struct ContentBudget: Codable, Hashable, Sendable {
    public var idealDuration: Double
    public var safeRange: ClosedRange<Double>
    public var absoluteCeiling: Double
    public var strongUnitCount: Int
    public var distinctEventCount: Int
    public var distinctSceneCount: Int
    public var distinctShotFamilyCount: Int
    public var usableActionSeconds: Double
    public var usableAtmosphereSeconds: Double
    public var usableSpeechSeconds: Double
    public var confidence: Double
    public var limitingFactors: [EditorialLimitingFactor]
}
```

Все новые persisted fields должны быть optional либо иметь безопасные decoder defaults, чтобы старые `.veloedit` пакеты продолжали открываться.

## 7. Целевая архитектура pipeline

Новый production flow:

`Media Analysis`
→ `Temporal Editorial Evidence`
→ `Shot Family Clustering`
→ `Event/Scene Reconstruction`
→ `Content Budget`
→ `Narrative Hypotheses`
→ `Coverage Plan`
→ `Sequence Search`
→ `Timeline Composition`
→ `Intent Enforcement`
→ `Rendered Evidence Review`
→ `Hard Gates`
→ `Transactional Repair`
→ `Variant Selection`
→ `Final Timeline`.

Ключевое изменение: `Content Budget`, `Shot Family` и `Narrative Beat` вычисляются до заполнения Timeline. Rendered review и hard gates выполняются до выбора победителя, а не только после того, как средний score уже назвал вариант лучшим.

## 8. Функциональные требования

### EI-01. Temporal Editorial Evidence

Для каждого candidate необходимо анализировать временную структуру, а не только агрегированный thumbnail/embedding.

Требования:

1. Для кандидата брать не менее 12 равномерных temporal samples; для фрагментов длиннее 12 с — не менее 24 samples или адаптивную частоту до 4 fps вокруг detected changes.
2. Отдельно сохранять состояния в точках entry, anticipation, peak, completion и exit.
3. Вычислять:
   - изменение положения/масштаба субъектов;
   - изменение позы или типа действия;
   - optical/motion energy;
   - смену композиции;
   - появление/исчезновение людей и объектов;
   - окклюзию;
   - длительность визуально неизменного участка;
   - вероятность подготовки камеры, случайного перекрытия объектива, опускания камеры и окончания записи.
4. Кадры, в которых более 28% полезной площади занимает случайная foreground-окклюзия, получают hard risk. Исключение возможно только для намеренного reveal с подтверждённой динамикой.
5. Candidate с хорошим peak, но плохими краями должен быть автоматически retrimmed вокруг сильной фазы.
6. Evidence должно кэшироваться по `contentHash + sourceRange + analysisVersion`.

Результат: `CandidateInsights` расширяется optional-полем `editorialEvidence`.

### EI-02. Shot Family Clustering и устранение повторов

Нужно заменить бинарную логику «duplicate / not duplicate» на многоуровневую оценку повторяемости.

Для каждой пары units вычисляются:

- `sourceOverlap`;
- `semanticSimilarity`;
- `compositionSimilarity`;
- `subjectStateSimilarity`;
- `cameraSetupSimilarity`;
- `actionSimilarity`;
- `backgroundSimilarity`;
- `temporalProximity`.

Hard duplicate определяется при выполнении любого условия:

- source overlap ≥ 0,18 для соседних клипов;
- source ranges имеют одинаковый start с допуском 2 frames;
- combined family similarity ≥ 0,92 и information gain второго фрагмента < 0,12;
- один фрагмент является почти полным подмножеством другого без отдельной функции reaction/detail.

Soft repetition определяется при combined similarity ≥ 0,78. Он допустим только если второй фрагмент:

- меняет фазу действия;
- показывает реакцию другого субъекта;
- меняет крупность минимум на один класс;
- завершает setup, созданный предыдущим кадром;
- является осознанным visual motif и разделён достаточным временем.

Ограничения последовательности:

- не более двух клипов одной `ShotFamily` подряд;
- совокупный непрерывный run одной семьи — не более 12 с для обычного монтажа и 20 с для documentary/atmospheric pattern;
- при наличии минимум трёх shot families доминирующая семья не должна занимать более 32% фильма;
- повтор семьи после паузы разрешён только при новом state/action evidence;
- одинаковый source range не допускается дважды без explicit user duplication.

### EI-03. Content Budget и честная длительность

Текущий расчёт не должен считать всю длительность исходных файлов доступным editorial ceiling. Наличие 18 минут записи не означает наличие 5 минут событий.

Алгоритм:

1. Устранить hard duplicates и выбрать лучший take внутри каждой семьи.
2. Для каждого unit определить `usableDuration`, ограниченную реальным действием и стабильными границами.
3. Применить diminishing return внутри семьи:
   - первый сильный unit: коэффициент 1,0;
   - второй с новым состоянием: до 0,65;
   - третий: до 0,35;
   - последующие: 0, если нет отдельного narrative purpose.
4. Атмосферный материал учитывать отдельно и ограничивать структурной долей фильма.
5. `absoluteCeiling` строить из usable units, а не из полной metadata duration исходников.
6. Расширять candidate range можно только до ближайшей подтверждённой boundary и только если temporal evidence показывает изменение, речь или завершение действия.
7. Запрещено расширять статичный участок только для достижения requested duration.

Обработка exact duration:

- `feasibility = absoluteCeiling / requestedDuration`;
- если feasibility ≥ 1,0, точная длительность остаётся hard constraint;
- если 0,85 ≤ feasibility < 1,0, выполняется второй candidate-mining pass по ещё не выбранным сценам и соседним диапазонам;
- если после второго pass feasibility < 1,0, duration становится `compromised`, а качество и отсутствие повторов имеют приоритет;
- если feasibility < 0,85, сразу создаётся лучший короткий монтаж в `safeRange`; Timeline не дополняется слабыми фрагментами;
- Director Conversation получает фактическую причину и рассчитанную поддерживаемую длительность;
- production validation не должна удалять хороший короткий Timeline только из-за невозможного exact target.

Необходимо различать:

- `requestedDuration` — пожелание пользователя;
- `supportedDuration` — доказанная материалом длительность;
- `committedDuration` — длительность принятого варианта;
- `durationConstraintStatus`: satisfied, expandedSearchSatisfied, compromisedInsufficientContent, failedTechnical.

### EI-04. Narrative Hypothesis Search

Перед Story Plan система должна построить от одной до пяти объяснимых гипотез истории.

Поддерживаемые базовые формы:

- journey/discovery;
- day/event chapters;
- preparation → action → result;
- problem → attempt → outcome;
- place → people → activity → closure;
- atmospheric observation;
- rapid highlight;
- minimal montage.

Каждая гипотеза оценивается по:

- evidence coverage;
- наличию реальных state changes;
- возможности построить hook и closure;
- event chronology;
- различию сцен и shot families;
- эмоциональному и action диапазону;
- доступному оригинальному звуку;
- соответствию пользовательскому prompt;
- поддерживаемой длительности.

Гипотеза отклоняется, если её роль можно заполнить только переименованием похожих клипов. Например, восемь одинаковых кадров поездки нельзя распределить как intro, buildup, climax и outro без подтверждённого изменения действия.

### EI-05. Проверяемые Narrative Beats

Story Engine должен создавать `NarrativeBeatPlan`.

Минимальные правила:

- первый смысловой beat появляется не позднее 8-й секунды;
- hook для фильма до 3 минут — в первые 3 с; для documentary/atmospheric допускается до 8 с;
- orientation не может занимать более 15% фильма;
- climax/peak должен отличаться от медианного action/emotion уровня минимум на 0,18 либо иметь подтверждённое смысловое завершение;
- closure обязан добавлять результат, реакцию, уход, возвращение к establishing image или явный end-card;
- outro не может занимать более 18% фильма без отдельного episodic structure;
- один role не может занимать более 55% фильма;
- для episodic/day story каждая смена события должна иметь визуальный bridge или chapter title;
- если доказанного climax нет, выбирается atmospheric/minimal pattern, а не искусственный climax label.

`TimelineSelfReviewer.missingStoryArc` должен стать ремонтируемой ошибкой. Текущий путь, в котором эта ошибка остаётся без repair, недопустим.

### EI-06. Coverage-first selection

Выбор клипов должен решать задачу покрытия функций, а не заполнения секунд.

Для каждого beat формируется coverage requirement:

- establishing;
- subject introduction;
- action start;
- action progression;
- peak/result;
- reaction;
- detail/cutaway;
- exit/closure.

Sequence search обязан учитывать marginal gain кандидата относительно уже выбранных units:

```text
marginalGain =
  narrativeCoverage
  + informationGain
  + actionStateChange
  + shotScaleNovelty
  + subjectPerspectiveNovelty
  + audioValue
  - repetitionPenalty
  - continuityCost
  - cropRisk
  - weakEdgePenalty
```

Кандидат с высоким isolated highlight score, но почти нулевым marginal gain не должен попадать в фильм.

Дополнительные ограничения:

- asset diversity измеряется не количеством файлов, а разнообразием событий и camera setups;
- нельзя считать два клипа разными только из-за разных `assetID`, если это одна сцена с почти одинаковой композицией;
- нельзя группировать весь материал одного asset подряд по умолчанию;
- chronological grouping допускается только внутри реального события и не отменяет shot-family limits;
- locked clips сохраняются, но surrounding montage обязан минимизировать их повторяемость.

### EI-07. Осмысленный порядок и continuity graph

Для выбранных units строится directed graph переходов. Стоимость ребра включает:

- event chronology violation;
- screen direction conflict;
- jump in subject position/scale;
- duplicate setup;
- необъяснимую смену локации/времени;
- audio discontinuity;
- отсутствие причинно-следственного перехода;
- слишком маленькое или слишком большое изменение энергии;
- crop center jump.

Положительные признаки перехода:

- action match;
- eyeline/movement match;
- wide → medium → detail;
- question → reaction/result;
- ambient/audio bridge;
- chapter boundary;
- мотивированная смена контраста или темпа.

Sequence optimizer выбирает путь с максимальным narrative gain при ограниченной continuity cost. Простая сортировка по asset/date/sourceStart не может быть финальным алгоритмом.

### EI-08. Ритм и длительность отдельных планов

Длительность плана должна зависеть от происходящего внутри кадра.

Базовые диапазоны до поправок на стиль:

| Тип момента | Обычный диапазон | Hard maximum без нового состояния |
|---|---:|---:|
| Action/highlight | 1,2–3,8 с | 5 с |
| Reaction | 1,5–4,5 с | 6 с |
| Establishing | 2,5–6 с | 8 с |
| Detail/B-roll | 1,2–3,5 с | 5 с |
| Atmospheric dynamic | 4–9 с | 12 с |
| Static observation | 2,5–6 с | 8 с |
| Complete speech phrase | по boundary | 20 с без внутреннего cutaway |
| Continuous meaningful action | по фазам действия | 15 с без доказанного progression |

Правила:

- одинаковая длительность большинства клипов считается pattern defect;
- если более 65% клипов имеют длительность в пределах ±2 frames от одного значения, создаётся finding `mechanicalCadence`;
- cut point выбирается по action, reaction, speech, audio onset или музыкальной фразе, а не по круглому числу секунд;
- beat-sync может сдвинуть boundary только внутри безопасного окна и не должен ломать moment completeness;
- музыкальная сетка не может превращать фильм в постоянные одинаковые двухтактовые блоки;
- длинный план разрешён, только если temporal evidence подтверждает progression или осознанную атмосферную паузу;
- внутри одного scene block должны присутствовать контролируемые вариации длины и крупности.

### EI-09. Render-aware smart reframe

Текущий двухточечный `SubjectReframePlan` необходимо расширить до многоточечной траектории.

Новая модель:

```swift
public struct ReframeKeyframe: Codable, Hashable, Sendable {
    public var sourceTime: Double
    public var centerX: Double
    public var centerY: Double
    public var scale: Double
    public var confidence: Double
}

public struct FramingSafetyReport: Codable, Hashable, Sendable {
    public var minimumPrimaryVisibility: Double
    public var minimumFaceVisibility: Double
    public var groupCoverage: Double
    public var edgeViolationSeconds: Double
    public var centerVelocity: Double
    public var centerAcceleration: Double
    public var cropJumpAtEntry: Double
    public var cropJumpAtExit: Double
    public var passed: Bool
    public var reasons: [String]
}
```

Требования:

1. Tracking выполняется для всех значимых людей/лиц/транспорта, а не только для одного `mainSubject`.
2. Выбор primary subject учитывает роль действия. Крупный неподвижный багги не должен вытеснять активного человека.
3. Для групповой сцены строится union/priority box с весами субъектов.
4. Горизонтальный 16:9 → вертикальный 9:16 проверяется на финальном viewport не менее чем в пяти точках клипа и на detected motion changes.
5. Минимальная видимость primary person — 92%; лица — 96%; для группы допускается меньше только при сохранении всех narrative-important subjects.
6. Safe margin для лица — не менее 8% короткой стороны viewport; для направления движения оставляется lead room.
7. Camera path сглаживается с ограничением скорости и ускорения. Резкий цифровой pan запрещён без реального резкого перемещения субъекта.
8. Если безопасный fill невозможен, fallback выбирается в таком порядке:
   - другой candidate/take;
   - другой source range;
   - мягкий `fit` или safe-fit background, если это не запрещено intent;
   - статичный crop, сохраняющий приоритетного субъекта;
   - исключение клипа.
9. Central crop не является безопасным fallback, если значимый субъект касается edge или находится вне центральной области.
10. Framing оценивается после реального compositing. Source thumbnail не является достаточным доказательством.
11. Между соседними клипами проверяется crop jump: центр главного субъекта не должен необъяснимо перескакивать через кадр.

### EI-10. Титры как часть структуры

Титры должны следовать Narrative Beat Plan.

Правила:

- project title создаётся только при наличии подтверждённой темы;
- chapter title создаётся при реальной смене дня, события, локации или активности;
- если фильм использует «День 1», последующие визуально явные дни получают соответствующую главу либо первый титр упрощается до общего названия;
- title не должен обещать только рыбалку, если значительная часть фильма посвящена велосипеду;
- каждый автоматически созданный title должен быть проверен на финальном кадре с учётом crop и safe areas;
- смысловой title не должен исчезать вследствие regenerate, если соответствующее событие осталось в фильме;
- pending instruction «добавь титры» считается выполненной только при фактическом добавлении и прохождении title quality gate;
- title density является верхним budget, а не причиной добавлять бессодержательные подписи;
- end title применяется только при наличии функции closure, а не для маскировки оборванного конца.

### EI-11. Жёсткий контракт оригинального звука

`DirectorBrief.sourceAudioPolicy` должен иметь приоритет над автономной оценкой полезности звука.

Правила:

- policy `remove/mute`: все embedded audio muted, `audioClips` пусты, sound bridges не создаются;
- policy `duck`: оригинальный звук допускается в ограниченных местах и с фактическим ducking музыки;
- policy `keep`: система сохраняет полезные события, но всё равно контролирует уровни и continuity;
- более поздний явный prompt обновляет policy атомарно;
- `AIDirectorEngine.initialDecisions` не может вернуть звук, запрещённый brief;
- detach audio не может обходить mute policy;
- regenerate обязан санитизировать legacy audio clips по актуальному intent до preview.

Технические требования к миксу:

- integrated loudness целевого фильма: ориентир −16 LUFS для обычного файла;
- true peak не выше −1 dBTP;
- музыка не должна перекрывать полезную речь;
- wind/handling noise без смысловой ценности подавляется или исключается;
- L/J-cut разрешён только при continuity gain и внутри разрешённой audio policy;
- музыка не обрывается случайно: используется phrase-aware trim/fade или бесшовное структурное продолжение;
- повтор музыкального фрагмента проверяется отдельно от визуальных повторов.

### EI-12. Семантический выбор музыки

Музыка оценивается относительно готовой narrative curve, а не только тегов отдельных кандидатов.

Music fit включает:

- mood compatibility;
- energy-curve correlation;
- event scale;
- наличие/отсутствие действия;
- acoustic density относительно original audio;
- длительность и возможность структурного монтажа;
- культурно-жанровую нейтральность при низкой уверенности;
- Personal Taste только после project fit.

Track с выраженным western/showdown или тревожным cinematic характером не должен автоматически использоваться для спокойной прогулки только из-за generic `adventure/cinematic` label.

Если `preferDifferentTrack == true`, предыдущий track ID получает hard exclusion, кроме случая, когда альтернатив нет; такой fallback обязан попасть в diagnostics.

### EI-13. Эффекты как мотивированное исключение

Clean image является default.

Автоматический эффект разрешён только при наличии одного из оснований:

- explicit creative request;
- подтверждённый narrative transition;
- конкретная техническая коррекция;
- устойчивый style motif, применённый последовательно;
- photo motion;
- очень сильный музыкальный/event accent и высокий confidence.

Запрещено:

- использовать pixelate, halftone, glitch, RGB split и аналогичные stylized effects без explicit intent или очень сильного semantic justification;
- ставить несколько несвязанных эффектов подряд на один короткий диапазон;
- менять visual language один раз в середине спокойного фильма;
- считать эффект самостоятельным information gain;
- компенсировать повторяющийся материал эффектами.

Hard limits:

- не более одного stylized effect на 45 с без explicit request;
- не более двух simultaneously stacked creative effects;
- technical correction не считается creative effect;
- effect confidence < 0,72 приводит к отказу от автоматического применения.

### EI-14. Meaningful telemetry

Telemetry показывается только тогда, когда значение помогает понять действие.

Условия:

- sensor data валидна и синхронизирована;
- значение или его производная превышают activity-specific threshold;
- метрика соответствует происходящему;
- overlay не закрывает лицо/героя/текст;
- событие длится достаточно долго для чтения;
- повтор overlay имеет новый информационный смысл.

G-force около 0–0,1 g при обычной спокойной езде не является достаточным основанием для HUD. В таком случае telemetry опускается без попытки заменить её декоративной анимацией.

### EI-15. Новые материалы и pending intent

Pipeline должен хранить `IntentLedger`:

```swift
public struct IntentLedgerEntry: Codable, Hashable, Sendable {
    public var id: UUID
    public var projectRevision: UInt64
    public var normalizedIntent: DirectorIntent
    public var source: IntentSource
    public var status: IntentStatus
    public var evidence: [IntentSatisfactionEvidence]
    public var failureReason: String?
}
```

Требования:

- каждый явный запрос получает typed intent;
- intent считается fulfilled только по состоянию сохранённого Timeline;
- фраза «учти новые материалы» требует оценить каждый asset, добавленный после предыдущего успешного Timeline;
- новый asset не обязан попасть в фильм, но для исключения нужна причина: duplicate, quality, no narrative fit, unsafe crop, unsupported media;
- background result с устаревшей revision не коммитится;
- при revision conflict pipeline автоматически повторяет дешёвую фазу планирования один раз на актуальном snapshot;
- дорогой media analysis не повторяется без изменения content hash/version;
- success message запрещён, если hard intent не выполнен;
- project без Timeline и с pending create intent должен восстанавливаться после повторного открытия и безопасно завершать либо перезапускать generation.

### EI-16. Rendered Evidence Review

Perceptual review должен анализировать то, что увидит зритель.

Для каждого final candidate timeline создаются review probes:

- первый meaningful frame;
- 25%, 50% и 75% каждого длинного клипа;
- frame перед и после каждой склейки;
- пик каждого effect/transition;
- первый читаемый frame каждого title;
- telemetry frame;
- точки максимального crop risk;
- финальный frame фильма.

Probes рендерятся через тот же composition path, что Preview/Export, с тем же canvas, crop, reframe, titles, effects и overlays.

Проверяются:

- black/blank frame;
- неверная ориентация;
- обрезанные лица и тела;
- значимый субъект вне viewport;
- случайная foreground-окклюзия;
- jump crop;
- нечитаемый title;
- конфликт title/telemetry/subject;
- эффект, уничтожающий читаемость;
- repeated final frames;
- preview/export signature mismatch.

Source thumbnail не может закрыть render-aware gate.

### EI-17. Sequence-level findings

Добавить новые finding types:

- `mechanicalCadence`;
- `shotFamilyRunTooLong`;
- `dominantSetup`;
- `lowInformationSpan`;
- `falseNarrativeRole`;
- `missingHook`;
- `missingClosure`;
- `eventTransitionWithoutBridge`;
- `chapterCoverageMismatch`;
- `unsafeReframe`;
- `cropJump`;
- `foregroundOcclusion`;
- `audioPolicyViolation`;
- `musicNarrativeMismatch`;
- `unmotivatedEffect`;
- `meaninglessTelemetry`;
- `pendingIntentUnsatisfied`;
- `durationPadding`;
- `staleGenerationResult`.

`lowInformationSpan` создаётся, если окно длительностью 20 с имеет низкий cumulative information gain и не является подтверждённой atmospheric pause. Для фильма длиннее 2 минут дополнительно проверяются окна 45 и 90 с.

### EI-18. Hard quality gates

Timeline не участвует в финальном pairwise tournament, если нарушено хотя бы одно условие:

- hard duplicate;
- audio policy violation;
- stale project revision;
- критический unsafe reframe;
- отсутствует primary video;
- отсутствует требуемый event/content intent;
- есть незакрытый required narrative beat;
- exact duration достигнута за счёт `durationPadding`;
- больше двух клипов одной shot family подряд без мотивированного progression;
- render probe обнаружил blank/invalid frame;
- preview/export contract не совпадает;
- automatic stylized effect нарушает explicit style intent;
- pending user instruction ошибочно помечена выполненной.

Hard gate возвращает типизированную причину и возможный repair class.

### EI-19. Новый порядок автоматического repair

Repair выполняется транзакционно в следующем порядке:

1. Устранить stale result и intent violation.
2. Устранить blank frame, broken source, audio policy и unsafe crop.
3. Удалить hard duplicates и пересекающиеся ranges.
4. Сократить low-information spans.
5. Перестроить shot-family runs и dominant setup.
6. Восстановить hook, progression, reaction и closure.
7. Исправить chapter/title coverage.
8. Удалить meaningless telemetry и unmotivated effects.
9. Исправить rhythm/cadence.
10. Пересобрать music alignment и mix.
11. Только после этого оптимизировать soft duration fit и style/taste.

Для `missingStoryArc`, `dominantSetup` и `lowInformationSpan` локального trim может быть недостаточно. Repair engine обязан уметь вызвать bounded structural replan выбранного event/scene block.

Ограничения:

- максимум три полных review iterations;
- максимум 24 speculative operations на вариант;
- после каждой принятой операции пересчитываются hard gates;
- repair не принимается только из-за роста среднего score, если критический finding остался;
- если исправить длинный вариант нельзя, создаётся короткий fallback из уже проверенных beats;
- committed result никогда не может быть хуже исходного по количеству critical/high findings.

## 9. Модель оценки вариантов

### 9.1. Отказ от одной компенсируемой суммы

Итоговый выбор должен быть лексикографическим:

1. `hardGatePassed`;
2. меньше critical findings;
3. меньше high findings;
4. выше editorial score;
5. выше intent satisfaction;
6. выше style/personal fit;
7. лучше duration fit внутри доказанного Content Budget.

### 9.2. Editorial score

Рекомендуемая модель:

```text
core = geometricMean(
  narrativeCoherence,
  informationDensity,
  momentCompleteness,
  shotFamilyDiversity,
  rhythmQuality,
  framingSafety,
  audioCoherence
)

craft = geometricMean(
  technicalQuality,
  continuity,
  titleQuality,
  musicNarrativeFit,
  styleFit
)

editorialScore = 0.78 * core + 0.22 * craft - explicitPenalties
```

Geometric mean используется намеренно: почти нулевой story/framing/audio компонент не должен скрываться набором средних технических оценок.

Обязательные penalties:

- hard/soft repetition;
- consecutive same-family duration;
- low-information windows;
- механическая cadence;
- weak opening/ending;
- unexplained event jump;
- crop risk;
- unmotivated decoration;
- impossible-duration padding.

`durationFit` не входит в `core`. Он используется только как tie-break после прохождения quality gates.

### 9.3. Минимальные пороги production winner

- `hardGatePassed == true`;
- critical findings = 0;
- high findings = 0 либо один документированный non-repairable warning без нарушения intent;
- `narrativeCoherence ≥ 0,68`;
- `informationDensity ≥ 0,64`;
- `shotFamilyDiversity ≥ 0,62` при наличии минимум трёх доступных families;
- `framingSafety ≥ 0,82`;
- `audioCoherence ≥ 0,75`;
- `editorialScore ≥ 0,72`;
- для автоматического creative effect `effectJustification ≥ 0,72`;
- для telemetry `telemetryNarrativeValue ≥ 0,65`.

Если ни один вариант не проходит пороги, система не выбирает «лучший из плохих» длинный фильм. Она строит conservative fallback меньшей длительности.

## 10. Требуемые изменения по существующим компонентам

| Компонент | Требуемое изменение |
|---|---|
| `DeepMediaUnderstanding.swift` | Добавить temporal editorial evidence, multi-subject priority, shot scale/angle/mount, occlusion и multi-keyframe reframe input. |
| `DeepMediaEnricher.swift` | Формировать `EditorialUnit`, information/action delta и shot-family features; версионировать кэш. |
| `EventIntelligence.swift` | Отличать event/scene от повторяющегося camera setup; сохранять state transitions и closure evidence. |
| `Models.swift` | Добавить optional `ContentBudget`, `EditorialEvidence`, `ShotFamily`, `NarrativeBeatPlan`, `IntentLedger`, `DurationConstraintStatus`, `FramingSafetyReport`. |
| `AutonomousDirector.swift` | Заменить source-material ceiling на evidence-based Content Budget; сделать explicit duration условно жёсткой, а не разрешением растягивать исходник. |
| `StoryEngine.swift` | Добавить Narrative Hypothesis Search, coverage-first marginal selection, family/run constraints и проверяемые beats. |
| `TimelineComposer.swift` | Перейти от заполнения target duration к beat allocations; динамические shot durations; строгий source-audio contract; chapter coverage. |
| `MontageVariantScoring.swift` | Добавить sequence features, geometric core score, hard gates и лексикографический comparator. |
| `AIDirectorEngine.swift` | Сделать `missingStoryArc` ремонтируемым; добавить structural block replan; запретить возврат запрещённого audio; ужесточить эффекты. |
| `PerceptualReview.swift` | Добавить rendered probes, low-information windows, cadence, family runs, crop/title/telemetry/effect review. |
| `PlaybackEngine.swift` | Предоставить дешёвый deterministic frame-probe API на общей composition; сохранить preview/export signature. |
| `VeloVideoCompositor.swift` | Поддержать multi-keyframe reframe и deterministic interpolation; возвращать framing diagnostics. |
| `ProfessionalPipeline.swift` | Выполнять render-aware preflight до принятия Timeline; hard framing/audio/intent gates. |
| `SmartTitleEngine.swift` / `AdaptiveTitleLayout.swift` | Проверять coverage событий, смысл title и финальную читаемость. |
| `MusicSyncEngine.swift` / `AdaptiveSoundtrack.swift` | Оценивать готовую narrative curve, loop/phrase continuity и реальный mix. |
| `VeloEditPipeline.swift` | Ввести atomic Intent Ledger, revision-aware retry и сохранение degraded-but-valid короткого результата. |
| `ProjectStore.swift` | Совместимо сохранять новые diagnostics, cache versions и intent status. |

## 11. Предлагаемые публичные внутренние интерфейсы

```swift
public protocol EditorialEvidenceAnalyzing: Sendable {
    func analyze(candidate: Candidate, asset: MediaAsset) async throws -> EditorialEvidence
}

public protocol ShotFamilyClustering: Sendable {
    func cluster(units: [EditorialUnit]) -> ShotFamilyIndex
}

public protocol ContentBudgeting: Sendable {
    func budget(
        units: [EditorialUnit],
        families: ShotFamilyIndex,
        requestedDuration: Double?,
        requestIsExplicit: Bool,
        style: DirectorStyleVector
    ) -> ContentBudgetDecision
}

public protocol NarrativePlanning: Sendable {
    func hypotheses(
        events: [Event],
        units: [EditorialUnit],
        budget: ContentBudget,
        intent: DirectorIntent
    ) -> [NarrativeHypothesis]
}

public protocol EditorialSequenceSearching: Sendable {
    func sequences(
        hypothesis: NarrativeHypothesis,
        units: [EditorialUnit],
        families: ShotFamilyIndex,
        budget: ContentBudget
    ) -> [EditorialSequence]
}

public protocol RenderedTimelineReviewing: Sendable {
    func review(
        timeline: Timeline,
        plan: StoryPlan,
        playback: PlaybackBuild
    ) async -> RenderedEditorialReview
}
```

Протоколы нужны для deterministic unit tests и для замены дорогого анализа fixtures без реального media decode.

## 12. Оркестрация создания фильма

Псевдокод production path:

```swift
let snapshot = await store.snapshot()
let intent = IntentResolver.resolve(snapshot.workspaceState)
let evidence = await EditorialEvidenceCache.enrich(snapshot.analyses)
let families = ShotFamilyClusterer.cluster(evidence.units)
var budget = ContentBudgetEngine.decide(evidence, families, intent)

if budget.requiresExpandedMining {
    let expanded = await CandidateMiner.expand(
        onlyUncoveredScenes: true,
        respecting: evidence.boundaries
    )
    evidence.merge(expanded)
    families = ShotFamilyClusterer.cluster(evidence.units)
    budget = ContentBudgetEngine.decide(evidence, families, intent)
}

let hypotheses = NarrativeHypothesisEngine.build(
    events: snapshot.events,
    evidence: evidence,
    budget: budget,
    intent: intent
)

let variants = hypotheses.flatMap {
    EditorialSequenceSearch.buildVariants(
        hypothesis: $0,
        evidence: evidence,
        families: families,
        budget: budget
    )
}

let directed = variants.map(composeAndDirect)
let reviewed = await directed.concurrentMap(renderProbeAndReview)
let eligible = reviewed.filter(\.hardGatePassed)
let winner = VariantSelector.lexicographicWinner(eligible)
    ?? ConservativeFallbackBuilder.build(from: reviewed, budget: budget)

try await store.commitIfRevisionMatches(
    winner,
    intentEvidence: winner.intentSatisfaction,
    expectedRevision: snapshot.revision
)
```

## 13. Диагностика и объяснимость

`DirectorRunSummary` должен дополнительно сохранять:

- Content Budget и duration feasibility;
- выбранную narrative hypothesis;
- beat coverage;
- shot-family histogram;
- максимальный same-family run;
- low-information windows;
- discarded candidates с reason codes;
- framing safety summary;
- audio intent audit;
- effect/telemetry justification;
- rendered probe count и timings;
- hard-gate results до и после repair;
- факт conservative fallback;
- intent ledger IDs, выполненные текущим Timeline.

Диагностика не должна сохранять transcript, абсолютные file paths, изображения или чувствительные GPS-данные в Personal Taste.

Human-readable причины должны быть конкретными:

- хорошо: «Запрошенные 300 с сокращены до 126 с: найдено 9 разных сильных моментов; дальнейшее расширение повторяло сцену у багги»;
- плохо: «Недостаточно материала»;
- хорошо: «GX… не использован: 4 кандидата визуально дублируют более сильный план той же сцены»;
- плохо: «Файл не подошёл».

## 14. Производительность и кэширование

### 14.1. Общие требования

- дорогой vision/audio анализ не повторяется при regenerate, если `contentHash` и analysis version не изменились;
- shot-family clustering работает по компактным feature vectors;
- rendered review использует ограниченные probes, а не полный export;
- варианты разделяют immutable analysis context;
- frame decode и probe render выполняются с bounded concurrency;
- cancellation проверяется между стадиями и внутри длинных media loops;
- старый background task не может коммитить результат после изменения проекта.

### 14.2. Целевые бюджеты после готового media analysis

На поддерживаемом Apple Silicon Mac для проекта до 20 минут исходников и до 300 editorial units:

- Content Budget + family clustering: ≤ 2 с;
- построение до пяти narrative hypotheses: ≤ 1 с;
- sequence search до десяти вариантов: ≤ 5 с;
- rendered probes одного варианта: ≤ 8 с в preview resolution;
- полный review/repair всех финалистов: ≤ 30 с;
- первый playable preview строится до завершения несущественных diagnostics;
- дополнительная память для sequence search: ≤ 600 MB.

Если бюджет превышен, сокращается число вариантов/probes, но не отключаются hard gates.

### 14.3. Версионирование кэша

Добавить независимые версии:

- `EditorialEvidenceCache.version`;
- `ShotFamilyIndex.version`;
- `RenderedProbeCache.version`;
- `IntentLedger.schemaVersion`.

Инвалидация должна быть адресной. Изменение музыки не инвалидирует vision evidence; смена canvas инвалидирует reframe и rendered probes, но не scene embeddings.

## 15. Тестовая стратегия

### 15.1. Unit tests

Добавить группы тестов:

#### Content budget

- полный source duration не считается usable duration;
- четыре длинных статичных кандидата не обеспечивают пяти минут;
- explicit duration запускает expanded mining, но не padding;
- impossible exact duration создаёт `compromisedInsufficientContent`;
- сильные уникальные моменты сохраняют requested duration, если реально покрывают её.

#### Shot families и повторы

- одинаковый setup из разных asset ID попадает в одну family;
- разные фазы одного действия могут остаться разными units;
- overlapping source ranges никогда не оказываются соседями;
- третий одинаковый setup подряд отклоняется;
- реакция другого человека не считается дублем основного action.

#### Story

- labels без evidence не закрывают beats;
- фильм без climax выбирает atmospheric/minimal pattern;
- episodic story создаёт chapter coverage;
- hook и closure имеют подтверждённые функции;
- `missingStoryArc` вызывает structural replan.

#### Rhythm

- 31 одинаковая длительность из 33 создаёт `mechanicalCadence`;
- статичный 26-секундный план сокращается;
- complete speech phrase не режется по среднему shot duration;
- action boundary важнее музыкального beat;
- длинный план с доказанным progression сохраняется.

#### Reframe

- активный человек приоритетнее крупного неподвижного транспорта;
- два человека сохраняются в group viewport;
- лицо не касается edge в 9:16;
- subject crossing использует промежуточные keyframes;
- unsafe fill выбирает alternate take или safe-fit;
- crop jump между соседними клипами обнаруживается.

#### Audio

- `sourceAudioPolicy.remove` удаляет embedded и detached audio;
- Director не возвращает звук после Composer;
- duck policy создаёт реальную automation;
- music replacement не выбирает предыдущий track;
- speech и полезный audio event сохраняют boundaries только при разрешённой policy.

#### Effects и telemetry

- calm footage не получает pixelate/halftone без explicit request;
- stacked effects превышают budget и отклоняются;
- 0,1 g без события не создаёт overlay;
- значимый telemetry peak может создать короткий акцент;
- overlay/title collision обнаруживается по rendered probe.

#### Intent/revision

- новый asset получает included/rejected evidence;
- stale background result не коммитится;
- один revision conflict вызывает безопасный replan;
- success message невозможен при pending intent;
- project without timeline сохраняет recoverable state.

### 15.2. Integration tests

Создать компактные synthetic fixtures без пользовательских медиа:

1. `RepeatedPOVCyclingFixture`: 12 похожих POV units, 3 уникальных события.
2. `StaticFishingFiveMinuteFixture`: длинные статичные ranges и короткие реальные actions.
3. `BuggyGroupVerticalFixture`: человек у края, крупный vehicle в центре, 9:16 output.
4. `MultiDayChapterFixture`: рыбалка, лагерь, велосипед, photo между днями.
5. `MutePolicyFixture`: embedded + detached + natural-sound candidates при hard mute.
6. `CalmStyleEffectFixture`: высокий technical quality, но отсутствие semantic effect justification.
7. `ImpossibleExactDurationFixture`: 45 с сильного материала при запросе 300 с.
8. `LongSpeechFixture`: законченные фразы и cutaways.

Каждый fixture должен проходить полный путь:

`Story → Composer → Director → Rendered Review → Repair → Winner`.

### 15.3. Регрессионные контракты по наблюдаемым проектам

Без привязки к UUID/названиям production-код должен обеспечивать:

#### Контракт A: сценарий «Мой фильм»

- hard repeated ranges = 0;
- одинаковых клипов одной family подряд ≤ 2;
- самый длинный same-family run ≤ 20 с;
- доля клипов одной точной длительности < 65%;
- foreground occlusion high-risk shots отсутствуют;
- dominant vehicle-body composition не проходит framing/visual gate;
- story pattern соответствует фактическим beats;
- meaningless G-force overlays = 0;
- pending title intent либо выполнен, либо generation не помечен успешным;
- итог не растягивается сверх Content Budget.

#### Контракт B: сценарий «тест 3»

- первые 90 с не могут состоять из одной shot family при отсутствии progression;
- непрерывный блок сидящих людей около 106 с невозможен;
- cycling event получает bridge/chapter либо входит в общую корректно названную историю;
- человек не обрезается vertical crop ради неподвижного багги;
- photo получает included/rejected reason;
- hard mute исключает detached sound;
- unmotivated pixelate/halftone отсутствуют;
- точные 300 с не достигаются padding;
- при недостатке материала создаётся более короткий passing fallback;
- финал содержит closure, а не случайный конец исходного range.

#### Контракт C: сценарий «тест 2»

- pending create intent имеет recoverable state;
- после повторного открытия pipeline может продолжить без повторного дорогого анализа;
- карточка summary не должна заявлять timeline preview, пока Timeline не существует;
- отсутствие валидного Timeline фиксируется как typed state, а не молчаливый успех.

### 15.4. Human evaluation

Перед включением по умолчанию провести blind review минимум на 20 проектах разных жанров.

Каждую пару current/new оценивают минимум три человека по шкалам:

- хочется ли проматывать;
- понятна ли история;
- есть ли повторы;
- естественен ли ритм;
- сохранён ли главный герой в кадре;
- уместны ли музыка/звук/эффекты;
- ощущается ли финал завершённым.

Критерий запуска:

- новая версия предпочтительнее минимум в 75% сравнений;
- не более 5% сравнений содержат новый critical defect;
- vertical framing предпочтительнее минимум в 85% проблемных 16:9 → 9:16 сцен;
- intent violations = 0.

## 16. Нефункциональные требования

- Determinism: одинаковые project snapshot, model versions и seed создают одинаковый winner.
- Idempotence: повторный review passing Timeline не меняет его без нового intent/evidence.
- Backward compatibility: старые manifests открываются без ручной миграции.
- Transactionality: неуспешный generation не повреждает последний playable Timeline.
- Cancellation: отменённая операция не сохраняет partial Timeline как успешный результат.
- Privacy: анализ остаётся локальным в рамках текущей архитектуры.
- Explainability: каждое автоматическое исключение и каждое нарушение exact duration имеет reason code.
- Preview/export parity: одинаковые crop, reframe, titles, effects, audio policy и timing.
- Testability: все stochastic/ML boundaries доступны через protocols и deterministic fixtures.

## 17. Запрещённые способы формального прохождения приёмки

Нельзя:

- special-case названия проектов, asset filenames, UUID или конкретные timestamps;
- просто сократить все фильмы до фиксированных 60/90 секунд;
- случайно перемешивать клипы для имитации разнообразия;
- менять `storyRole`, не меняя сам порядок и content evidence;
- скрывать findings из diagnostics;
- повышать score изменением весов без фактического улучшения последовательности;
- добавлять переходы/эффекты между дублями вместо удаления дублей;
- растягивать speed или source range для достижения длительности;
- использовать black bars как постоянное решение vertical framing без прохождения fallback policy;
- оценивать crop только по исходному thumbnail;
- считать intent выполненным по наличию tool call, если Timeline не содержит результата;
- ухудшать последний валидный Timeline при неуспешном regenerate.

## 18. Этапы реализации

### Этап 1. Observability и hard contracts

- Intent Ledger;
- duration status;
- новые sequence findings;
- audio policy audit;
- hard-gate result в diagnostics;
- регрессионные fixtures A/B/C.

Результат этапа: текущие плохие варианты ещё могут строиться, но больше не могут молча считаться production winner.

### Этап 2. Content Budget и Shot Families

- temporal evidence;
- shot-family clustering;
- evidence-based duration;
- marginal-gain selection;
- run/dominance constraints.

Результат: устранены растягивание, группировка по asset и большинство визуальных повторов.

### Этап 3. Narrative Beat Planner и structural repair

- hypothesis search;
- beat coverage;
- continuity graph;
- hook/closure gates;
- block replan для missing story/low-information spans.

Результат: Timeline становится историей, а не списком кандидатов.

### Этап 4. Render-aware framing

- multi-subject tracking priority;
- multi-keyframe reframe;
- safe-fit fallback;
- rendered probes;
- crop continuity.

Результат: vertical preview сохраняет людей и смысл кадра.

### Этап 5. Sound, music, titles, effects и telemetry

- строгий audio contract;
- narrative music fit;
- chapter coverage;
- effect/telemetry justification;
- overlay collision review.

Результат: оформление перестаёт противоречить истории.

### Этап 6. Calibration и rollout

- human blind review;
- performance benchmark;
- калибровка thresholds на разных жанрах;
- project-local feature flag только для разработки;
- включение по умолчанию после достижения критериев.

Feature flag не должен становиться новой пользовательской настройкой.

## 19. Definition of Done

Работа считается завершённой, когда одновременно выполнены условия:

1. Все новые unit/integration/regression tests проходят.
2. Полный существующий test suite не имеет regressions.
3. `./Scripts/build-app.sh` успешно собирает полный `VeloEdit.app` bundle.
4. Три наблюдаемых сценария проходят контракты A/B/C без special cases.
5. Ни один production winner не содержит critical hard-gate finding.
6. Exact duration не достигается за счёт повторов или пустого расширения source ranges.
7. Hard mute невозможно обойти detached или regenerated audio.
8. Vertical 9:16 сохраняет narrative-important subjects на rendered probes.
9. `missingStoryArc`, `dominantSetup` и `lowInformationSpan` имеют рабочий structural repair.
10. Preview и export имеют одинаковую editorial signature.
11. Pending intent получает доказуемый fulfilled/rejected status.
12. Human evaluation достигает порогов раздела 15.4.
13. Diagnostics позволяют объяснить длительность, порядок, исключения, crop, звук и оформление без чтения исходного кода.

## 20. Итоговый критерий качества

Главный вопрос новой системы перед сохранением фильма:

> Если убрать имя исходного файла, технический score и требование заполнить длительность, даёт ли следующий фрагмент зрителю достаточно нового, чтобы оправдать ещё несколько секунд внимания?

Если ответ отрицательный и нет доказанной функции атмосферы, речи, реакции или завершения действия, фрагмент не должен попадать в production Timeline.
