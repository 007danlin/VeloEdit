# Публикация veloedit.ru

Заглушка находится в `website/index.html`. Она работает без сборки и внешних зависимостей.
Workflow `.github/workflows/pages.yml` публикует только содержимое `website/`.

1. Загрузить `website/index.html` и `.github/workflows/pages.yml` в ветку `main`.
2. Открыть https://github.com/007danlin/VeloEdit/settings/pages и выбрать
   **Build and deployment → Source → GitHub Actions**.
3. Во вкладке **Actions** запустить **Deploy website to GitHub Pages → Run workflow**, если публикация ещё не запущена.
4. Дождаться успешного выполнения и проверить https://007danlin.github.io/VeloEdit/.
5. В **Settings → Pages → Custom domain** указать `veloedit.ru` и сохранить.
6. У DNS-провайдера домена добавить записи ниже. Если домен использует DNS REG.RU,
   редактировать их в панели REG.RU. Заменить конфликтующие записи парковки для `@`
   и `www`; записи почты и подтверждения владения сохранить.

| Тип | Имя / Subdomain | Значение |
| --- | --- | --- |
| A | @ | 185.199.108.153 |
| A | @ | 185.199.109.153 |
| A | @ | 185.199.110.153 |
| A | @ | 185.199.111.153 |
| CNAME | www | 007danlin.github.io |

7. После успешной проверки DNS и выпуска сертификата включить **Enforce HTTPS**.
   Обновление DNS и доступность HTTPS могут занять до 24 часов.

При публикации через GitHub Actions файл `CNAME` не используется: домен задаётся
в настройках Pages. Сначала добавить домен в GitHub, затем менять DNS.

Документация:
- https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
- https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site
