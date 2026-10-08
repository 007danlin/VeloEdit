# Разработка VeloEdit

## Быстрый цикл

```bash
./Scripts/dev-build.sh --jobs 2
./Scripts/dev-test.sh --jobs 2
.build/arm64-apple-macosx/debug/veloedit-cli help
```

Скрипты используют активный Xcode toolchain и кэш в `~/Library/Caches/VeloEditBuild`.
Полный bundle после изменений кода или ресурсов обязательно пересобирается:

```bash
./Scripts/build-app.sh
```

Результат находится в `Build/VeloEdit.app`. Для исходников нужен Git LFS:
бинарные ресурсы Ollama должны быть загружены командой `git lfs pull`.

`output/` содержит только локальные эксперименты. В `Docs/Validation/` Git
хранит текстовые выводы и Python-скрипты; сырые логи, JSON/JSONL, скриншоты,
экспорты и архивы создаются локально. Ссылки из исторических отчётов на них
не означают, что эти данные входят в свежий checkout. Тестовые входные данные
следует помещать в `Tests/Fixtures/`, а ресурсы приложения — в `Resources/`.
Не удаляйте `Package.resolved`, Cargo lockfiles, исходники `ThirdParty/` и их
лицензии при очистке: они нужны для воспроизводимой сборки и уведомлений.

## Targets

- `VeloEditCore`: модели и сервисы без SwiftUI/AppKit.
- `VeloEdit`: macOS SwiftUI app.
- `veloedit-cli`: smoke, batch workflow и diagnostics.
- `VeloEditCoreTests`: Swift Testing unit/integration checks.

## Definition of done

Изменение должно собирать все targets, проходить tests, не менять оригиналы и обновлять `TODO.md`, `CHANGELOG.md`, `ARCHITECTURE.md`. Media/render изменения дополнительно проверяются на реальном файле в подписанном app host.
