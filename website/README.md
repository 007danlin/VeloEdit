# Публикация veloedit.ru

Лендинг публикуется Cloudflare Pages из репозитория `007danlin/VeloEdit`.
Проект: `veloedit`, production branch: `main`, framework: None,
build command: `exit 0`, output directory: `website`, root directory: корень репозитория.
Push в main автоматически запускает публикацию. GitHub Pages отключён.

Домены `veloedit.ru` и `www.veloedit.ru` подключаются через Custom domains проекта,
затем соответствующие CNAME указывают на `veloedit.pages.dev`. Записи GitHub A и
TXT `_github-pages-challenge-007danlin` больше не нужны. Почтовые записи сохраняются.
`www` перенаправляется на основной HTTPS-домен через `website/_redirects`.

Кнопка скачивания запрашивает последний опубликованный DMG через GitHub API.
Резервный `/release.json` обслуживает Cloudflare Function из `functions/release.json.js`:
он получает текущий релиз на сервере с кэшем до пяти минут. При недоступности GitHub
остаётся статический `website/release.json` — его следует обновлять при изменении сайта.
Бинарные файлы остаются в GitHub Releases. `/updates/appcast.xml` перенаправляет на
подписанный appcast последнего релиза. Само приложение использует GitHub напрямую.

Локальный просмотр: `python3 -m http.server 8765 --directory website` (без Functions).
Проверка выбора DMG: `node --test Tests/Website/release.test.mjs`.
Подготовка обновлений приложения: [руководство по выпуску](../Docs/Guides/release.md).
