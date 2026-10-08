# Final Cut Pro export

`FCPXMLExporter` создаёт FCPXML 1.11 с format/assets/library/event/project/sequence/spine. Asset resources ссылаются на оригинальные file URLs; каждый clip сохраняет source start, duration, timeline offset, lock metadata и explanation. Constant speed, multi-point speed ramp, freeze и reverse передаются через `timeMap`, fill/fit — через `adjust-conform`, поворот/mirror — `adjust-transform`, opacity — `adjust-blend`, громкость — `adjust-volume`. Overlay-клипы экспортируются отдельной lane. Доступны варианты `edit` и `selects`.

`FCPXMLCapabilities` ограничивает экспорт известными возможностями. Непредставимые color/motion/audio-processing/telemetry/transition параметры не получают выдуманный Final Cut effect UID. Точные значения сохраняются в `com.veloedit.*` metadata.

При таком intent `VeloEditPipeline.exportFCPXML` автоматически рендерит рядом `<name>-rendered-reference.mp4`. В event появляются два проекта: `Editable` с оригинальными ссылками и редактируемыми нативными параметрами и `Rendered Reference` с точным результатом VeloEdit. Пользователь может продолжить монтаж исходников и сверять/использовать точный вариант; оригинальные файлы не изменяются. Если весь timeline выражается нативно, лишний intermediate не создаётся.

`FCPXMLFixtureFactory` генерирует 10 обязательных сценариев ТЗ. Тесты проверяют well-formed XML, escaping, оригинальный URL и source ranges. Семантический import в Final Cut остаётся release gate, потому что Final Cut не установлен в текущей среде.
