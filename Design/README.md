# Графика VeloEdit

Здесь хранятся исходники и варианты графики для дальнейшей работы.

| Папка | Содержимое |
| --- | --- |
| [Icons](Icons/) | Варианты иконки и изображение для README |
| [FirstLaunch](FirstLaunch/README.md) | Графика первого запуска и описание её подготовки |

Готовые ресурсы приложения находятся в `Resources/`, включая
`Resources/AppIcon.icns` и `Resources/FirstLaunch/`.
Изменение картинки в `Design/` само по себе не обновляет приложение:
подготовьте нужный ресурс в `Resources/` и выполните `./Scripts/build-app.sh`.

Иконка для macOS 14/15 содержит прозрачные углы во всех размерах `.icns`:
эти системы не должны зависеть от автоматической маски новых версий macOS.
Исходный рисунок сохранён без перерисовки в `Icons/AppIcon-source.png`.
Для воспроизводимой упаковки со скруглением и отступами:

```sh
swift Scripts/Tools/build-app-icon.swift Design/Icons/AppIcon-source.png Resources/AppIcon.icns
./Scripts/build-app.sh
```
