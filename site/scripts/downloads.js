(function () {
  'use strict';

  var REPO = 'Tribunus-dev/tessera';
  var API_LATEST = 'https://api.github.com/repos/' + REPO + '/releases/latest';
  var FALLBACK_URL = 'https://github.com/' + REPO + '/releases';

  function assetUrl(tag, name) {
    return 'https://github.com/' + REPO + '/releases/download/' + tag + '/' + name;
  }

  function pickAsset(assets, pattern) {
    for (var i = 0; i < assets.length; i++) {
      if (pattern.test(assets[i].name)) return assets[i];
    }
    return null;
  }

  function setLink(id, href, label) {
    var el = document.getElementById(id);
    if (!el) return;
    if (href) {
      el.href = href;
      el.removeAttribute('aria-disabled');
      if (label) el.textContent = label;
    }
  }

  function setCommand(id, text) {
    var el = document.getElementById(id);
    if (el && text) el.textContent = text;
  }

  function render(release) {
    var tag = release.tag_name;
    var assets = release.assets || [];
    var macArm = pickAsset(assets, /bin-macos-arm64/i) || pickAsset(assets, /macos.*arm64/i);
    var macX64 = pickAsset(assets, /bin-macos-x64/i) || pickAsset(assets, /macos.*x64/i);
    var linuxX64 = pickAsset(assets, /bin-ubuntu-x64/i) || pickAsset(assets, /ubuntu.*x64/i);
    var linuxArm = pickAsset(assets, /bin-ubuntu-arm64/i) || pickAsset(assets, /ubuntu.*arm64/i);

    var hasAssets = assets.length > 0;
    var status = document.getElementById('download-status');
    if (status) status.textContent = hasAssets ? 'Latest ' + tag : 'No binaries attached yet — install from source or check releases.';

    if (macArm) {
      setLink('dl-mac-arm', assetUrl(tag, macArm.name), 'Download arm64');
      setCommand('dl-mac-arm-cmd', 'curl -L -o ' + macArm.name + ' ' + assetUrl(tag, macArm.name) + ' && tar -xzf ' + macArm.name);
    } else if (hasAssets && macX64) {
      setLink('dl-mac-arm', assetUrl(tag, macX64.name));
    } else {
      setLink('dl-mac-arm', FALLBACK_URL);
    }

    if (macX64) {
      setLink('dl-mac-x64', assetUrl(tag, macX64.name));
      setCommand('dl-mac-x64-cmd', 'curl -L -o ' + macX64.name + ' ' + assetUrl(tag, macX64.name) + ' && tar -xzf ' + macX64.name);
    } else {
      setLink('dl-mac-x64', FALLBACK_URL);
    }

    if (linuxX64) {
      setLink('dl-linux-x64', assetUrl(tag, linuxX64.name));
      setCommand('dl-linux-x64-cmd', 'curl -L -o ' + linuxX64.name + ' ' + assetUrl(tag, linuxX64.name) + ' && tar -xzf ' + linuxX64.name);
    } else {
      setLink('dl-linux-x64', FALLBACK_URL);
    }

    if (linuxArm) {
      setLink('dl-linux-arm', assetUrl(tag, linuxArm.name));
    } else {
      setLink('dl-linux-arm', FALLBACK_URL);
    }

    var tags = document.querySelectorAll('[data-release-tag]');
    for (var i = 0; i < tags.length; i++) tags[i].textContent = hasAssets ? tag : 'master-fff0e0e (pre-release)';
  }

  function init() {
    var status = document.getElementById('download-status');
    fetch(API_LATEST, { headers: { 'Accept': 'application/vnd.github+json' } })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(render)
      .catch(function () {
        if (status) status.textContent = 'Releases unavailable — see GitHub releases.';
      });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
