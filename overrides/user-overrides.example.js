/* user-overrides.example.js
 *
 * Optional personal overrides for the firefox-hardened stack.
 * Append (or merge) these into your profile's user.js AFTER the firefox-debloat managed
 * block and AFTER any Arkenfox/Betterfox content, so that these values win (user.js
 * applies top-to-bottom, last value wins).
 *
 * Rename to user-overrides.js and edit to taste. Nothing here is required.
 */

/* ---------- Stay logged in ---------- */
// Do not clear cookies/site data on close (keeps you signed in).
user_pref("privacy.clearOnShutdown_v2.cookiesAndStorage", false);
// Keep browsing history and form data across sessions.
user_pref("privacy.clearOnShutdown_v2.browsingHistoryAndDownloads", false);
user_pref("privacy.clearOnShutdown_v2.formdata", false);
user_pref("privacy.clearOnShutdown_v2.historyFormDataAndDownloads", false);
// Cache still cleared on close (frees disk, low privacy risk).

/* ---------- Anti-fingerprinting ---------- */
// RFP: strong anti-fingerprinting. May force GMT timezone + light theme + window sizing.
// Disable if it breaks sites you need. (FPP via ETP Strict stays on either way.)
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.pbmode", true);

/* ---------- Speed ---------- */
// Re-enable speculative loading (privacy trade-off, but faster page loads).
user_pref("network.prefetch-next", true);
user_pref("network.dns.disablePrefetch", false);
user_pref("network.dns.disablePrefetchFromHTTPS", false);
user_pref("network.http.speculative-parallel-limit", 6);
user_pref("browser.urlbar.speculativeConnect.enabled", true);
user_pref("browser.places.speculativeConnect.enabled", true);

/* ---------- New tab page ---------- */
// New tab page enabled so Tabliss can render (Tabliss replaces about:newtab).
user_pref("browser.newtabpage.enabled", true);
// If you prefer a populated new tab page instead, comment the line above and use:
// user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
// user_pref("browser.newtabpage.activity-stream.feeds.section.highlights", false);
// user_pref("browser.newtabpage.activity-stream.showSponsored", false);
// user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);

/* ---------- Disk cache (optional, for speed) ---------- */
// Uncomment to enable disk cache for faster repeat loads (privacy trade-off).
// user_pref("browser.cache.disk.enable", true);

/* ---------- Sync ---------- */
// If you use Firefox Sync, keep this true (and run firefox-debloat with -KeepSync / --keep-sync).
// user_pref("identity.fxaccounts.enabled", true);
