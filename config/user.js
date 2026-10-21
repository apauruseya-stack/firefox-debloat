// firefox-debloat prefs. The scripts copy this file into a delimited block in each profile's
// user.js. To stop applying a pref, delete the line (or comment it out with //) and run the
// script again.

// --- Telemetry ---
// Turns off sending technical and interaction data to Mozilla.
user_pref("datareporting.healthreport.uploadEnabled", false);
// Turns off data submission as a whole.
user_pref("datareporting.policy.dataSubmissionEnabled", false);
// Turns off the daily usage ping.
user_pref("datareporting.usage.uploadEnabled", false);
// Turns off extended telemetry collection.
user_pref("toolkit.telemetry.enabled", false);
// Turns off unified (base) telemetry.
user_pref("toolkit.telemetry.unified", false);
// Points the telemetry server to an empty address.
user_pref("toolkit.telemetry.server", "data:,");
// Does not store pings locally.
user_pref("toolkit.telemetry.archive.enabled", false);
// Does not send the new-profile ping.
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
// Does not send a ping when the browser closes.
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
// Does not send a ping after updates.
user_pref("toolkit.telemetry.updatePing.enabled", false);
// Does not send UI hang reports (Background Hang Reporter).
user_pref("toolkit.telemetry.bhrPing.enabled", false);
// Does not send the first-shutdown ping.
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
// Opts out of telemetry coverage measurement.
user_pref("toolkit.telemetry.coverage.opt-out", true);
// Opts out of toolkit coverage measurement.
user_pref("toolkit.coverage.opt-out", true);
// Removes the coverage endpoint.
user_pref("toolkit.coverage.endpoint.base", "");
// Turns off new tab page telemetry.
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
// Turns off new tab page telemetry (submission).
user_pref("browser.newtabpage.activity-stream.telemetry", false);
// Turns off ad attribution measurement (Privacy-Preserving Attribution).
user_pref("dom.private-attribution.submission.enabled", false);

// --- Studies ---
// Does not take part in studies (Shield).
user_pref("app.shield.optoutstudies.enabled", false);
// Turns off Normandy, which applies experiments and remote pref changes.
user_pref("app.normandy.enabled", false);
// Removes the Normandy server address.
user_pref("app.normandy.api_url", "");

// --- Crash reports ---
// Removes the crash report submission address.
user_pref("breakpad.reportURL", "");
// Does not send reports for crashed tabs.
user_pref("browser.tabs.crashReporting.sendReport", false);
// Does not automatically send pending crash reports.
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);

// --- Ads and sponsored content ---
// Hides sponsored content on the new tab page.
user_pref("browser.newtabpage.activity-stream.showSponsored", false);
// Hides sponsored shortcuts on the new tab page.
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
// Hides recommended stories on the new tab page.
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
// Removes the default shortcuts from the new tab page.
user_pref("browser.newtabpage.activity-stream.default.sites", "");
// Turns off sponsored suggestions in the address bar.
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
// Turns off Firefox Suggest suggestions in the address bar.
user_pref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
// Turns off trending searches in the address bar.
user_pref("browser.urlbar.trending.featureGate", false);

// --- Recommendations and promotions ---
// Hides the recommendations pane in the add-ons manager.
user_pref("extensions.getAddons.showPane", false);
// Turns off recommendations in about:addons.
user_pref("extensions.htmlaboutaddons.recommendations.enabled", false);
// Turns off personalized extension recommendations.
user_pref("browser.discovery.enabled", false);
// Turns off extension suggestions while you browse.
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
// Turns off feature suggestions while you browse.
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);
// Hides the "More from Mozilla" section in settings.
user_pref("browser.preferences.moreFromMozilla", false);
// Turns off Mozilla VPN promotions.
user_pref("browser.vpn_promo.enabled", false);
// Skips the welcome screen.
user_pref("browser.aboutwelcome.enabled", false);
// Does not ask whether Firefox should be the default browser.
user_pref("browser.shell.checkDefaultBrowser", false);

// --- AI ---
// The AIControls policy already covers these; the prefs reinforce them in user-only mode.
// Blocks the sidebar chatbot.
user_pref("browser.ai.control.sidebarChatbot", "blocked");
// Blocks AI-generated key points in link previews.
user_pref("browser.ai.control.linkPreviewKeyPoints", "blocked");
// Blocks AI tab group suggestions.
user_pref("browser.ai.control.smartTabGroups", "blocked");
// Blocks AI-generated alt text in the PDF viewer.
user_pref("browser.ai.control.pdfjsAltText", "blocked");
// Blocks Smart Window.
user_pref("browser.ai.control.smartWindow", "blocked");
// Blocks speech recognition.
user_pref("browser.ai.control.speechRecognition", "blocked");
// Turns off the AI chatbot.
user_pref("browser.ml.chat.enabled", false);
// Turns off link previews.
user_pref("browser.ml.linkPreview.enabled", false);

// --- Account and Sync ---
// Turns off Firefox Account and Sync (the DisableAccounts policy also locks this pref).
user_pref("identity.fxaccounts.enabled", false);

// --- Passwords, autofill and payments ---
// Disables Firefox's built-in password manager (Proton Pass replaces it).
user_pref("signon.rememberSignons", false);
user_pref("signon.autofillForms", false);
// Disables address autofill.
user_pref("extensions.formautofill.addresses.enabled", false);
// Disables credit card autofill.
user_pref("extensions.formautofill.creditCards.enabled", false);
// Disables Web Payments (Payment Request API).
user_pref("dom.payments.request.supported", false);
// Default search engine is set via the SearchEngines policy (Brave Search).
