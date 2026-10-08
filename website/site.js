import { selectRelease, latestReleaseURL } from './release.mjs';
const links = [...document.querySelectorAll('[data-download]')];
const status = document.querySelector('[data-release-status]');
async function readRelease(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(6500), cache: 'no-cache' });
  if (!response.ok) throw new Error('Release unavailable');
  const release = selectRelease(await response.json());
  if (!release) throw new Error('No universal DMG');
  return release;
}
async function resolveDownload() {
  // GitHub is authoritative; the deployment snapshot also works when its API is rate-limited.
  try { return await readRelease('https://api.github.com/repos/007danlin/VeloEdit/releases/latest'); }
  catch { try { return await readRelease(new URL('release.json', import.meta.url)); } catch { return null; } }
}
const ready = resolveDownload().then(release => {
  if (release) {
    links.forEach(link => { link.href = release.url; });
    status.textContent = `${release.version} · DMG · ${Math.round(release.bytes / 1024 / 1024)} МБ`;
  } else {
    status.textContent = 'Установщик доступен на странице последнего релиза';
  }
  return release;
});
links.forEach(link => link.addEventListener('click', async event => {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  status.textContent = 'Открываем установщик…';
  const release = await ready;
  window.location.assign(release?.url || latestReleaseURL);
  status.textContent = release ? `${release.version} · Загрузка DMG` : 'Открываем GitHub Releases';
}));
