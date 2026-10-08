const repository = 'https://github.com/007danlin/VeloEdit/';
export function selectRelease(release) {
  if (!release || release.draft || release.prerelease || !Array.isArray(release.assets)) return null;
  const assets = release.assets.filter(asset => {
    if (!/\.dmg$/i.test(asset.name || '') || !(asset.size > 0)) return false;
    try {
      const url = new URL(asset.browser_download_url);
      return url.origin === 'https://github.com' && url.pathname.startsWith('/007danlin/VeloEdit/releases/download/') && !url.username && !url.password;
    } catch { return false; }
  });
  const asset = assets.find(item => /universal/i.test(item.name)) || (assets.length === 1 ? assets[0] : null);
  if (!asset) return null;
  return { url: asset.browser_download_url, version: String(release.tag_name || ''), bytes: asset.size };
}
export const latestReleaseURL = repository + 'releases/latest';
