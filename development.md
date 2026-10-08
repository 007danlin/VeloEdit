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
хранит проверочные Python-скрипты; отчёты прогонов, логи, JSON/JSONL, скриншоты,
экспорты и архивы создаются локально. Для новых результатов используйте `Build/`.
Исторические аудиты удалены из текущего дерева; ссылки на них в технических
заданиях ведут к зафиксированной версии в истории Git. Требования и тесты
сохранены, а прежний успешный прогон не считается проверкой текущей сборки.
Тестовые входные данные следует помещать в `Tests/Fixtures/`, а ресурсы
приложения — в `Resources/`.
Не удаляйте `Package.resolved`, Cargo lockfiles, исходники `ThirdParty/` и их
лицензии при очистке: они нужны для воспроизводимой сборки и уведомлений.

Например, прежний аудит можно прочитать без восстановления файла в проекте:
`git show 8646d9d:EDITOR_TOOLKIT_AUDIT.md`.

## Targets

- `VeloEditCore`: модели и сервисы без SwiftUI/AppKit.
- `VeloEdit`: macOS SwiftUI app.
- `veloedit-cli`: smoke, batch workflow и diagnostics.
- `VeloEditCoreTests`: Swift Testing unit/integration checks.

## Definition of done

Изменение должно собирать все targets, проходить tests, не менять оригиналы и обновлять `TODO.md`, `CHANGELOG.md`, `ARCHITECTURE.md`. Media/render изменения дополнительно проверяются на реальном файле в подписанном app host.
