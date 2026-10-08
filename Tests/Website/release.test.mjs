import { test } from 'node:test';
import assert from 'node:assert/strict';
import { selectRelease } from '../../website/release.mjs';
const dmg = { name: 'VeloEdit_0.2.0.dmg', size: 300, browser_download_url: 'https://github.com/007danlin/VeloEdit/releases/download/v0.2.0/VeloEdit_0.2.0.dmg' };
const release = assets => ({ tag_name: 'v0.2.0', assets });
test('uses latest DMG regardless of versioned filename', () => assert.equal(selectRelease(release([dmg])).url, dmg.browser_download_url));
test('prefers universal when architecture-specific downloads exist', () => assert.equal(selectRelease(release([dmg, {...dmg, name:'VeloEdit-universal.dmg'}])).version, 'v0.2.0'));
test('does not guess an architecture when multiple DMGs are offered', () => assert.equal(selectRelease(release([dmg, {...dmg, name:'VeloEdit-arm64.dmg'}])), null));
test('rejects draft, prerelease, missing installer and external download hosts', () => {
  for (const value of [null, {}, release([]), {...release([dmg]), draft:true}, {...release([dmg]), prerelease:true}, release([{...dmg, browser_download_url:'https://example.com/VeloEdit.dmg'}]), release([{...dmg, browser_download_url:'https://github.com/attacker/VeloEdit/releases/download/v1/VeloEdit.dmg'}]), release([{...dmg, size:0}])]) assert.equal(selectRelease(value), null);
});
