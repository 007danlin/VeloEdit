import { selectRelease } from '../website/release.mjs';

// Fetch on Cloudflare so visitors do not depend on direct GitHub API access.
export async function onRequestGet(context) {
  try {
    const upstream = await fetch('https://api.github.com/repos/007danlin/VeloEdit/releases/latest', {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'VeloEdit-website' },
      cf: { cacheTtl: 300, cacheEverything: true },
      signal: AbortSignal.timeout(5000),
    });
    if (!upstream.ok) throw new Error('Release lookup failed');
    const release = await upstream.json();
    if (!selectRelease(release)) throw new Error('Release has no valid DMG');
    return Response.json({
      tag_name: release.tag_name, draft: false, prerelease: false,
      assets: release.assets.map(({ name, size, browser_download_url }) => ({ name, size, browser_download_url })),
    }, { headers: { 'Cache-Control': 'public, max-age=60, s-maxage=300' } });
  } catch {
    return context.next();
  }
}
