# Waze feature parity

Date: 2026-10-22. A researched list of what the Waze app does, mapped to what OpenWaze has,
has ticketed, or is missing. Use it to pick tickets, not as a spec: each row that becomes work
gets its own issue with acceptance criteria.

Sources: the Waze Help Center (`support.google.com/waze`), Waze Partners Help, `waze.com`
partner pages and forum announcements, the App Store listing, and Google/Waze press posts.
Tech press (9to5Google, MacRumors, Android Authority, TechCrunch, Malaysian outlets) fills
gaps and is marked **(press)**. Waze is closed source, so anything about how a feature works
inside (ranking, thresholds, data sources) is inferred and marked **(inferred)**.

Status key: **Done** (merged on `main`), **In PR** (open PR number), **Ticketed #n**,
**Missing**. Priority: **P0** must for v1, **P1** should, **P2** later, **P3** skip.

Legal caution: do not copy Waze's name in the product, its icons, moods/avatars, sounds,
voices, strings or help text. "Waze" appears in this repo only as a comparison point and in
the `waze-parity` label. Report icons, chimes and copy must be our own. Map data stays
OpenStreetMap (ODbL); never import Waze map or report data.

OpenWaze state checked against `main` at `dcecbf0` plus open PRs #48, #49, #53 and issues
1-64 (roadmap #64).

## 1. Navigation and routing

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Turn-by-turn navigation | Route to a destination with spoken and on-screen maneuvers; automatic reroute on live traffic, incidents and closures. | [App Store listing](https://apps.apple.com/us/app/id323229106) | Done (#10, PR #34) | P0 | OSRM demo server, dev-only. Production routing needs #41. |
| Destination search | Search places and addresses; recent and saved places; voice search (now Gemini). | [Gemini search, MacRumors (press)](https://www.macrumors.com/2026/07/13/five-new-waze-features-rolling-out/) | Done (#9 Photon, #18 saved/recent) | P0 | Photon public instance is dev-only. Voice search: Missing, see section 7. |
| Alternative routes | Shows several routes with ETA before Go; traffic-aware ETA; offers a faster route mid-drive. | (inferred from app behaviour; help centre has no single page) | In PR #49 (#14) | P0 | OSRM `alternatives=3`. ETA from live traffic needs #13 app side. |
| Avoid tolls / freeways / ferries / HOV | Settings and per-route toggles; applies to future drives. | [Help 6262566](https://support.google.com/waze/answer/6262566) | Ticketed #30 (tolls), #22 (settings) | P0 | Tolls are P0 for Malaysia. OSRM `exclude=toll` needs our own router (#41). Freeways/ferries: Missing, cheap once #41 exists. |
| HOV / subscription toll passes | Vehicle type or a listed pass lets Waze route via HOV or express lanes. | [Help 7490936](https://support.google.com/waze/answer/7490936) | Missing | P3 | No HOV lanes in Malaysia. Skip. |
| Toll cost estimate | Shows estimated toll price for the route (Malaysia since 2019, crowd-contributed). | [SoyaCincau 2019 (press, BM)](https://bm.soyacincau.com/2019/11/25/fungsi-terbaru-waze-beritahu-anda-jumlah-bayaran-tol-untuk-ke-destinasi-tersebut) | Missing | P1 | Open alternative: OSM `toll:*`/`charge` tags are sparse. Build an open toll-rate table per plaza (LLM publishes rates) and sum plazas on the route. Needs a data-maintenance ticket. |
| Route preview | Route line, ETA, distance and alternatives shown before Start. | (inferred) | Done (PR #37) | P0 | |
| Add a stop (one stop per route) | Add one stop during the drive from the ETA panel. | [Help 6262564](https://support.google.com/waze/answer/6262564) | Missing | P1 | OSRM supports waypoints already. Small UI work. |
| Planned drives, leave-by reminder | Plan a drive with an "Arrive at" time; traffic-based time-to-leave notification. | [Help 6378906](https://support.google.com/waze/answer/6378906), [Help 7502125](https://support.google.com/waze/answer/7502125) | Missing | P2 | Needs historical traffic to be useful; we have none yet. Needs "always" location for accurate reminders, which conflicts with our "when in use" rule. Do a simple version: scheduled local notification using the ETA at plan time. |
| Calendar sync | Reads the device default calendar; events with an address become planned drives. | [Help 6341187](https://support.google.com/waze/answer/6341187) | Missing | P3 | Privacy cost (calendar read) vs low value. Skip for v1. |
| Voice guidance | Spoken maneuvers; sound modes Normal / Less chatty / Alerts only / Off. | [Help 6273671](https://support.google.com/waze/answer/6273671) | Done (`Speech.swift`, AVSpeech) | P0 | Sound modes: Ticketed #22 (voice on/off, volume). "Less chatty" and "Alerts only": Missing, small. |
| Voice choice, celebrity voices, record your own | Pick a voice; time-limited celebrity voices; record your own prompt set and share it. | [Help 9943580](https://support.google.com/waze/answer/9943580), [Help 7388769](https://support.google.com/waze/answer/7388769) | Missing | P2 | Voice pick = `AVSpeechSynthesisVoice` list, cheap. Record-your-own is P2. Celebrity voices are licensed deals: not copyable. |
| Bahasa Malaysia voice | Two BM voice options including Yasmin Yusuff (2020). | [Malay Mail (press)](https://www.malaymail.com/news/life/2020/10/26/iconic-radio-presenter-yasmin-yusoff-is-the-bahasa-malaysia-voice-of-waze/1916375) | Ticketed #28 (BM localisation) | P0 | iOS ships a `ms-MY` system voice, so BM prompts are free once strings are localised. |
| Lane guidance | Lane arrows at junctions; roundabout lane guidance (2026). | [9to5Google Jan 2026 (press)](https://9to5google.com/2026/01/22/waze-speed-bump-new-features-rolling-out/) | Ticketed #23 | P1 | OSRM `intersections[].lanes`. Roundabout exits are in OSRM steps. |
| Speedometer and speed limit | Speedometer, limit sign, threshold and chime. | [Help 6386895](https://support.google.com/waze/answer/6386895) | In PR #48 (#15) | P0 | OSM `maxspeed` via Overpass. Overpass public instance is dev-only; cache by way or move to route annotations from our router. |
| Speed-limit-drop alert | Warns before the limit drops ahead. | [9to5Google Jan 2026 (press)](https://9to5google.com/2026/01/22/waze-speed-bump-new-features-rolling-out/) | Missing | P2 | Derived from `maxspeed` along the route once #48 lands. |
| Road-feature warnings | Speed bumps, sharp curves, toll booths, railway crossings ahead. Railway crossings in Malaysia since 2020. | [Help 15152735](https://support.google.com/waze/answer/15152735), [SoyaCincau (press)](https://soyacincau.com/?p=239636) | Missing | P1 | All in OSM: `traffic_calming=*`, `railway=level_crossing`, `barrier=toll_booth`; curves from route geometry. Fold into #16 "alerts ahead". |
| Reroute | Recalculates when off route. | (inferred) | Done (`Navigator.swift`, 5 s off-route) | P0 | |
| Learned / personalised routes | Ranks routes by past trips; can be turned off. | [MacRumors (press)](https://www.macrumors.com/2026/07/13/five-new-waze-features-rolling-out/) | Missing | P3 | Needs trip history on device or server. Conflicts with "no history" privacy stance. Skip. |
| Offline / poor network | Reports made offline are saved and sent on reconnect; routing and traffic need data. | [Help 13739612](https://support.google.com/waze/answer/13739612) | Ticketed #58 | P0 | Malaysian highways and tunnels. |
| ETA and arrival | ETA shown and updated; share from the ETA bar. | [Help 6273627](https://support.google.com/waze/answer/6273627) | Done (ETA), share see section 4 | P0 | |

## 2. Crowd reports

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Report flow | Report button, pick a type, optional subtype, submit; location captured at the tap; ~1 report/min cap; spam blocking. | [Help 13739290](https://support.google.com/waze/answer/13739290) | Done (#11, PR #38) | P0 | Our own icons and copy. Rate limit on server by `deviceId`. |
| Traffic | Jam report with severity (moderate, heavy, standstill). | (inferred; help page lists Traffic on car displays) [Help 7441088](https://support.google.com/androidauto/answer/7441088) | Done (`traffic` type, no severity) | P0 | Severity subtype: Missing, small. |
| Police | Police with subtypes mobile camera, hidden, other side (not everywhere). | [Help 13739289](https://support.google.com/waze/answer/13739289) | Done (`police`, no subtypes) | P0 | Subtypes: Missing, P1. Legal note: police-location reporting is legal in Malaysia as far as we found; verify before launch. |
| Crash | Crash with subtypes pile-up, other side. | [Help 13739612](https://support.google.com/waze/answer/13739612) | Done (`accident`) | P0 | Subtypes: Missing, P1. |
| Hazard subtypes | On road: construction, object, pothole, car on shoulder, animals; weather: fog, hail, flood, ice; roadkill, etc. | [Help 13739290](https://support.google.com/waze/answer/13739290) | Done (`hazard` + `flood`), other subtypes Missing | P1 | Add subtype field to the API (`hazard.pothole` etc). Flood is a top-level type here on purpose (#27). |
| Road closure | User-reported closure; partner closures from Map Editor or feed appear in 1-4 min; reopened when driving is detected. | [Partners 10617147](https://support.google.com/waze/partners/answer/10617147) | Done (`closure` type) | P0 | Closure does not yet affect routing. Routing around closures needs our router (#41) plus a closures feed into it: Missing, P1. |
| Bad weather, blocked lane | Separate items on car displays. | [Help 7441088](https://support.google.com/androidauto/answer/7441088) | Missing | P2 | Subtypes of hazard. |
| Speed / red-light cameras | Camera alerts from the editor-maintained map; Malaysia AES/AwAS fixed cameras widely reported. | [App Store listing](https://apps.apple.com/us/app/id323229106), [Carlist (press)](https://www.carlist.my/news/2025-update-aes-awas-speed-trap-camera-locations-on-malaysian-highways-145064/145064/) | Ticketed #16 (OSM `highway=speed_camera`) | P0 | Open source: OSM `highway=speed_camera`, `enforcement=*`. Malaysia coverage in OSM is incomplete; needs a mapping drive. AwAS average-speed sections (NKVE, DUKE, MEX trial) need `enforcement=average_speed` relations. |
| Map issue report | Report a map problem (wrong turn, missing road, closed road) to editors; now also via Gemini. | [Help 15714791](https://support.google.com/waze/answer/15714791) | Ticketed #21 (OSM Notes API) | P1 | Open alternative is better: fixes land in OSM for everyone. |
| Confirm / "Still there?" | Thumbs up or "Not there" on passing a report; stale reports expire. | (inferred) | Done (`StillThere.swift`, votes) | P0 | 2 downvotes expire a report. |
| Hands-free report (Talk to report, conversational) | Describe the hazard in plain speech; Gemini picks the category; follow-up questions; works on CarPlay/Android Auto; in Malaysia since 2025. | [Help 15714791](https://support.google.com/waze/answer/15714791), [Says.com (press)](https://says.com/my/tech/waze-voice-reporting) | Ticketed #62 (Siri App Intents, quick-report row) | P0 | On-device `SFSpeechRecognizer` plus keyword match covers 90% without an LLM. No audio leaves the device. |
| Near-real-time delivery | Reports from other drivers appear on the map quickly. | (inferred) | Ticketed #61 (SSE) | P1 | |
| Report points and thanks | Points per report; "thanks" from other drivers. | [Help 6273662](https://support.google.com/waze/answer/6273662) | Missing | P2 | See gamification, section 4. |
| Chat / comments on reports | Comment on a report; message other drivers. | [Help 6268714](https://support.google.com/waze/answer/6268714) (mentions messaging) | Missing | P3 | Moderation cost, no accounts. Skip. |
| Gas price reports | Users update fuel prices near a station. | [Help 13739802](https://support.google.com/waze/answer/13739802) | Missing | P3 for crowd entry | Malaysia fuel prices are fixed weekly by the government (RON95/diesel) and published; RON97 floats. Open alternative: a weekly price table, no crowd entry. P2 as a display feature. |

## 3. Live traffic and map

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Live traffic colouring | Road colours from driver speeds; feeds ETA and rerouting. | [App Store listing](https://apps.apple.com/us/app/id323229106) | Server Done (PR #45), app Ticketed #13 | P0 | Our probe design is anonymised by trip, not device (`docs/privacy.md` s.5). Needs App Attest (#46) against forgery. |
| Historical traffic for ETA | ETA uses typical speeds by time of day. | (inferred) | Missing | P2 | Aggregate per cell, hour, weekday on the server, no trip ids. Needs a privacy row before merge. |
| Map tiles and style | Proprietary map, day/night. | [Help 13772684](https://support.google.com/waze/answer/13772684) | Done (OpenFreeMap Liberty), dark map Ticketed #22 | P0 | OpenFreeMap has no service promise; self-host tiles for production (new ticket). |
| 3D / car puck | Animated car icon, selectable car icons. | [Help 13775134](https://support.google.com/waze/answer/13775134) | Ticketed #51 | P1 | Own designs only. |
| Live Map (web) | Public web map of traffic and reports. | [Broadcasters page](https://www.waze.com/broadcasters) | Partly Done (share-ETA viewer page) | P2 | A public web map of reports is cheap on top of `GET /reports` and the viewer page. |
| Partner hazards (emergency vehicles, crash hotspots, pothole programs) | Emergency vehicle alerts (US, MX, CA, FR); 2017 Shell Helix crash-hotspot pop-ups in Malaysia; Selangor pothole reporting. | [9to5Google (press)](https://9to5google.com/2026/01/22/waze-speed-bump-new-features-rolling-out/), [Paultan 2017 (press, BM)](https://paultan.org/2017/05/26/shell-helix-dan-aplikasi-navigasi-waze-lancar-sistem-mesej-amaran-kawasan-kemalangan-pertama-di-asia/) | Missing | P2 | Not copyable (partner feeds). Open alternative: MIROS/JKJR publish accident blackspot lists; import as a static layer if licence allows. Emergency vehicles need a government feed; skip. |

## 4. Driver UX, social, gamification

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Home screen, navigation chrome | Search bar, ETA bar, report button, auto-hiding top bar. | (inferred) | Done (#36, PR #37) | P0 | |
| Dark mode | Always, never, at night, or follow system. | [Help 13772684](https://support.google.com/waze/answer/13772684) | Ticketed #22 | P0 | Theme already has dark tokens; map style switch is the work. |
| Settings and onboarding | Settings menu; first-run permissions. | (inferred) | Ticketed #22 | P0 | Includes the PDPA notice (privacy.md s.8). |
| Share drive / ETA | Share a live link from the ETA bar; stop sharing any time. | [Help 6273627](https://support.google.com/waze/answer/6273627) | Server Done (PR #47), app Ticketed #19 | P1 | Token in URL fragment, 4 h cap. |
| Share a location | Send a place to friends or other apps. | [Help 6286096](https://support.google.com/waze/answer/6286096) | Missing | P2 | iOS share sheet with a `geo:` or OSM link. Small. |
| Friends, see friends on map, messaging | Social layer with friends' positions and chat. | [Help 6268714](https://support.google.com/waze/answer/6268714) | Missing | P3 | Needs accounts and persistent location; against our privacy model. Skip. |
| Points, levels, badges, leaderboards | 5 pts per drive, 6 per report, 3 per edit; levels; achievements. | [Help 6273662](https://support.google.com/waze/answer/6273662), [Help 6273631](https://support.google.com/waze/answer/6273631) | Missing | P2 | Local-only counters (drives, reports, confirmations) with no server scoreboard keep privacy intact. No leaderboards. |
| Moods / avatars | Mood icons shown to others on the map. | (inferred; no help page found) | Missing | P3 | Waze's moods are their art. Skip; a plain puck is enough. |
| Vehicle type (private, taxi, motorcycle), motorcycle mode | Vehicle type affects routing/ETA; 2026 Motorcycle mode (Malaysia in first wave). | [Help 7579259](https://support.google.com/waze/answer/7579259), [MacRumors (press)](https://www.macrumors.com/2026/07/13/five-new-waze-features-rolling-out/) | Missing | P1 | Malaysia has a very high motorcycle share; motorcycle lanes exist on federal roads (OSM `motorcycle=designated`). OSRM has a bicycle profile; a motorcycle profile is a Lua file on our router (#41). |
| Electric vehicle: plug types, charging along route | Set plug types; stations on route. | [Help 13259753](https://support.google.com/waze/answer/13259753) | Missing | P2 | OSM `amenity=charging_station` with `socket:*`. Overpass or our own POI index. |
| Fuel: preferred brand and type, prices, sort | Preferred fuel type, station sort by price. | [Help 6274027](https://support.google.com/waze/answer/6274027) | Missing | P2 | OSM `amenity=fuel`, government weekly price table. |
| Parking: find and book | Parking near destination; booking via third parties. | [Help 7052890](https://support.google.com/waze/answer/7052890), [Help 15113600](https://support.google.com/waze/answer/15113600) | Missing | P2 (find), P3 (book) | OSM `amenity=parking`. Booking needs partner deals: not copyable. |
| Trip suggestions, favourites | Suggests likely destinations; favourites. | [Help 9747181](https://support.google.com/waze/answer/9747181) | Done (saved and recent, #18); suggestions Missing | P2 | Suggestions need on-device history only. |
| Audio player / music control | Mini player for Spotify, Apple Music, YouTube Music and others. | [Help 9171270](https://support.google.com/waze/answer/9171270) | Ticketed #63 | P2 | iOS limits control of other apps; Spotify needs a client ID (maintainer blocker). |
| Custom car icons and themes | Choose a car icon; seasonal themes. | [Help 13775134](https://support.google.com/waze/answer/13775134) | Ticketed #51 (puck) | P2 | Own art. |
| School zones | School-zone alerts in some regions. | (unverified; no help page found) | Missing | P2 | OSM `hazard=school_zone`, `amenity=school` proximity plus time of day. Malaysia relevance: high (JKJR school-zone campaigns). |
| Alerts customisation | Choose which alert types to hear or see. | [Help 13786535](https://support.google.com/waze/answer/13786535) | Missing | P1 | Settings toggles once #16 exists. |

## 5. Integrations

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Apple CarPlay | Split map and panel; report menu; search. | [Help 9123774](https://support.google.com/waze/answer/9123774) | Ticketed #20 | P1 | Needs the CarPlay navigation entitlement from Apple (maintainer blocker). |
| Android Auto, Waze built-in (AAOS) | Full navigation on car displays. | [Help 7441088](https://support.google.com/androidauto/answer/7441088), [Help 12400321](https://support.google.com/waze/answer/12400321) | Ticketed #59, #60 | P2 | After the Android app. |
| Siri Shortcuts | Custom phrases under Voice and sound. | [Help 9245980](https://support.google.com/waze/answer/9245980) | Ticketed #62 | P0 | App Intents cover both Siri and Shortcuts. |
| Google Assistant / Gemini | Voice search and reporting. | [MacRumors (press)](https://www.macrumors.com/2026/07/13/five-new-waze-features-rolling-out/) | Missing | P2 | Not copyable as such. On-device speech plus intent matching is the open route (#62). |
| Navigate from other apps / Google Maps hand-off | Deep links (`waze://`), share a place from Google Maps. | [Help 10389770](https://support.google.com/waze/answer/10389770), [Help 16334835](https://support.google.com/waze/answer/16334835) | Missing | P1 | Register a URL scheme and `geo:` handling, plus a Universal Link. Small. |
| Bluetooth audio routing | Play prompts through car speakers or phone. | [Help 6291187](https://support.google.com/waze/answer/6291187) | Partly Done (ducking) | P1 | Add an output option in settings (#22). |
| Apple Watch | No official Waze watch app found. | (unverified) | Missing | P3 | Skip. Live Activity reaches the watch Smart Stack for free. |
| Live Activities, Dynamic Island, widgets | Not confirmed for Waze. | (unverified) | Missing | P1 | A navigation Live Activity (next turn, ETA) is cheap in SwiftUI and helps when the phone is locked. |
| Calendar | See section 1. | | Missing | P3 | |

## 6. Partner and business

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Waze for Cities data program | Free two-way exchange with agencies: closures and events in, incident feeds and BigQuery access out. | [Partners 10618477](https://support.google.com/waze/partners/answer/10618477), [Feed specs 13458165](https://support.google.com/waze/partners/answer/13458165) | Partly: `GET /reports` is public already | P1 | Open alternative is stronger: publish reports and traffic levels as open data (ODbL), GeoJSON/GeoRSS feed, plus a documented closures-in feed for JKR, LLM, DBKL, PLUS. |
| Partner closures feed (XML/JSON, email) | Agencies push closures; lane closures not supported. | [Partners 10618039](https://support.google.com/waze/partners/answer/10618039) | Missing | P1 | Needed for Malaysian expressway works. Ties to routing around closures. |
| Waze for Broadcasters | On-air tools and embeddable map for TV. Deprecation announced 2022; page still live. | [Broadcasters page](https://www.waze.com/broadcasters), [Forum notice](https://www.waze.com/discuss/t/heads-up-deprecating-the-broadcasters-program/244135) | Missing | P3 | Embeddable live map covers the useful part (section 3). |
| Waze Ads (pins, search, takeovers via Google Ads) | Advertisers buy pins; live in Malaysia. | [Forum: Waze Ads are back](https://www.waze.com/discuss/t/waze-ads-are-back-and-here-s-how-to-buy-them/398689) | Missing | P3 | No ads (privacy.md s.4 Disclosure). Skip. |
| Partner marketing hub, brand voices | Sponsored voices (Altimet with Liberty Insurance, 2017). | [Liberty (press)](https://www.libertyinsurance.com.my/news/altimet-the-first-malaysian-rapper-to-be-a-waze-voice-in-partnership-with-liberty-insurance-berhad) | Missing | P3 | Not copyable. Community-recorded voices (P2) instead. |

## 7. Map editing community

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Waze Map Editor (WME) | Web editor; edit only where you have driven recently. | [Help 6270175](https://support.google.com/waze/answer/6270175) | Not applicable | P0 (by design) | Our map is OSM: iD/JOSM are the editors. Document the "fix it in OSM" loop in the app (#21). |
| Editor levels 1-6, champs, staff approval | Automatic to level 3 by edit count; 4-6 by approval. | [Help 6264191](https://support.google.com/waze/answer/6264191) | Not applicable | P3 | OSM has no levels; do not invent them. |
| Suggest an edit, review suggestions | Users suggest; editors review. | [Help 14324943](https://support.google.com/waze/answer/14324943) | Ticketed #21 (OSM Notes) | P1 | |
| Closures by editors | Editors add timed closures. | [Partners 10617147](https://support.google.com/waze/partners/answer/10617147) | Missing | P1 | OSM has no live closures. Keep closures in our reports server (already), feed them to our router. |
| Edit points | 3 points per edit. | [Help 6273662](https://support.google.com/waze/answer/6273662) | Not applicable | P3 | |

## 8. Accessibility, privacy, account

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| Account: Google sign-in, email verification for points | Points need a verified email; account for sync. | [Help 6273662](https://support.google.com/waze/answer/6273662) | No accounts by design | P0 (keep none) | Client-chosen `deviceId` only. |
| Delete account, recent-locations management | Delete account removes saved places and history; manage recent locations. | [Help 6262602](https://support.google.com/waze/answer/6262602), [Help 6262570](https://support.google.com/waze/answer/6262570) | Missing | P0 | We need: "Reset device id", "Clear saved and recent places", operator delete-by-`deviceId` command (privacy.md s.4 Access). |
| Invisible mode | Hide from the map; cannot report while invisible; Waze still collects location. | [Help 6268714](https://support.google.com/waze/answer/6268714) | Done by design (never shown to others) | P0 | Probe opt-out (#13, #22) is our equivalent. |
| Privacy controls, data sharing with third-party apps | Settings page; third-party connections. | [Help 6071193](https://support.google.com/waze/answer/6071193), [Help 7245173](https://support.google.com/waze/answer/7245173) | Ticketed #22, #31 | P0 | PDPA notice, probe toggle, third-party list. |
| Accessibility (VoiceOver, Dynamic Type) | No dedicated Waze help page found; AppleVis users report partial VoiceOver support. | [AppleVis (press)](https://www.applevis.com/apps/ios/navigation/waze-navigation-live-traffic) | Missing (no audit yet) | P1 | Audit VoiceOver labels on report buttons and the maneuver banner; Dynamic Type; 3:1 icon contrast is already in `ReportsUI`. |
| Report abuse / spam limits | Rate limits; blocking heavy reporters. | [Help 13739290](https://support.google.com/waze/answer/13739290) | Done (server rate limits), attestation Ticketed #46 | P0 | |
| Carpool | Shut down September 2022. | [TechCrunch (press)](https://techcrunch.com/2022/08/26/googles-waze-shutting-down-its-carpool-service/) | Missing | P3 | Skip. |

## 9. Malaysia specifics

| Feature | What Waze does | Source | OpenWaze status | Priority | Notes |
|---|---|---|---|---|---|
| AES / AwAS camera alerts | Fixed and average-speed cameras shown as camera alerts (community-maintained). | [Carlist (press)](https://www.carlist.my/news/2025-update-aes-awas-speed-trap-camera-locations-on-malaysian-highways-145064/145064/) | Ticketed #16 | P0 | OSM coverage gap; organise a mapping task (MapRoulette). |
| Toll cost and avoid tolls | Toll estimate and avoidance. | see section 1 | Ticketed #30 | P0 | Rate table from LLM/concessionaires; verify licence. |
| Flood reports | Hazard > weather > flood. | [Help 13739290](https://support.google.com/waze/answer/13739290) | Done (#27, 120 min) | P0 | Add JPS public flood warnings as a layer if licence allows (P2). |
| Motorcycle mode | 2026, Malaysia in first wave. | [MacRumors (press)](https://www.macrumors.com/2026/07/13/five-new-waze-features-rolling-out/) | Missing | P1 | See section 4. |
| Bahasa Melayu UI and voice | BM voices; localised UI. | [Malay Mail (press)](https://www.malaymail.com/news/life/2020/10/26/iconic-radio-presenter-yasmin-yusoff-is-the-bahasa-malaysia-voice-of-waze/1916375) | Ticketed #28 | P0 | Also Chinese (Simplified) and Tamil: Missing, P2. |
| Railway crossing alerts | Added for Malaysia in 2020. | [SoyaCincau (press)](https://soyacincau.com/?p=239636) | Missing | P1 | OSM `railway=level_crossing`; fold into #16. |
| Local partnerships (Shell, Liberty, Selangor pothole program) | Sponsored alerts and voices; council pothole intake. | see sections 3, 6 | Missing | P2 | Open alternative: pothole reports exported to councils via the open feed. |
| km/h, KL defaults | | | Done (#29) | P0 | |

## Top 20: build next (ranked)

1. Merge #48 speedometer and speed limits (P0, in PR).
2. Merge #49 alternative routes and traffic-aware ETA (P0, in PR).
3. #22 settings, onboarding, PDPA notice, dark map (P0).
4. #62 hands-free reporting: App Intents, quick-report row, on-device speech (P0).
5. #16 alerts ahead: reports, speed cameras, railway crossings, speed bumps, toll booths (P0/P1, widen scope with OSM road features).
6. #13 app side of live traffic probes (P0).
7. #58 offline queue and poor-network behaviour (P0).
8. #41 self-hosted router for Malaysia (P0; unlocks tolls, closures, motorcycle profile).
9. #30 toll badge and avoid tolls, then toll cost table (P0/P1).
10. #28 Bahasa Melayu localisation and `ms-MY` voice (P0).
11. Data controls: reset device id, clear places, operator delete-by-id (P0, no ticket).
12. #46 App Attest for probes and reports (P0).
13. Report subtypes: police, crash, hazard subtypes, traffic severity (P1, no ticket).
14. #23 lane guidance and roundabout exits (P1).
15. #19 app side of share ETA (P1).
16. Navigation Live Activity (P1, no ticket).
17. Closures in the router plus partner closures feed in (P1, no ticket).
18. Open data out: GeoJSON feed of reports and traffic levels (P1, no ticket).
19. Deep links and `geo:` hand-off from other apps (P1, no ticket).
20. #21 map issue to OSM Notes (P1).

## Missing features with no ticket yet

Proposed ticket titles (one line each; file after review, not from this doc):

- Report subtypes: police (camera, hidden, other side), crash (pile-up, other side), hazard (pothole, object, construction, car on shoulder, animal), traffic severity
- Road-feature warnings from OSM: speed bumps, sharp curves, toll booths, railway crossings (extend #16)
- Speed-limit-drop warning ahead on route
- Add one stop to the current route
- Avoid freeways and ferries options (after #41)
- Toll cost estimate: open toll-rate table per plaza, summed on the route
- Routing around active closure reports (router side, after #41)
- Partner closures feed in: JSON schema and import for road agencies
- Open data out: GeoJSON/GeoRSS feed of reports and traffic levels with ODbL attribution
- Data controls in settings: reset device id, clear saved and recent places; operator delete-by-deviceId command
- Navigation Live Activity and Dynamic Island: next turn, distance, ETA
- Deep links: URL scheme, `geo:` URIs and Universal Links to open a destination
- Share a location via the iOS share sheet
- Sound modes: less chatty and alerts only
- Pick a navigation voice from the system voices
- Alert type toggles in settings (which alerts to hear or see)
- Motorcycle mode: motorcycle routing profile and lane preference for Malaysia
- School zone warnings from OSM schools and time of day
- EV charging stations along the route with plug-type filter (OSM)
- Fuel stations with the weekly government price table
- Parking near destination from OSM
- Local points and badges with no server scoreboard
- Accessibility audit: VoiceOver labels, Dynamic Type, reduced motion
- Historical per-cell speeds for better ETA (needs a privacy row)
- Public web map of live reports (reuse the share viewer page)
- Self-hosted tiles and Photon for production
- Planned drive: local leave-by notification from ETA at plan time
- Chinese and Tamil localisation

## Deliberately skip

- **Friends, messaging, moods/avatars, leaderboards.** Need accounts and persistent location sharing; against the no-account, no-history model in `docs/privacy.md`. Waze's moods and avatars are also their art.
- **Carpool.** Waze itself shut it down in 2022.
- **Waze Ads, sponsored pins, sponsored voices, parking booking.** Partner and ad deals; the project has a no-ads, no-disclosure rule. Not copyable and not wanted.
- **Celebrity voices.** Licensed. Offer community-recorded voices later instead.
- **Calendar sync and learned/personalised routes.** Read more personal data than the value returned; both conflict with "collect only what a feature needs".
- **HOV and subscription toll-pass routing.** No HOV lanes in Malaysia.
- **Waze-style editor levels and WME.** The map is OSM; its tools and community already exist. Do not build a second editor or rank system.
- **Gemini-style LLM reporting in the cloud.** Sends audio or text off the device. On-device speech plus intent matching does the job.
- **Emergency vehicle alerts.** Needs a government vehicle feed that does not exist here.
- **Apple Watch app.** A Live Activity reaches the watch already.

## Sources not verified

- Waze help pages that returned 404 or were not fetched directly: the conversational reporting page (15714791), the gas-price pages, and the July 2026 `blog.google` post; those rows cite press coverage instead.
- School zones, Live Activities, widgets and Apple Watch: no official Waze page found either way; marked unverified.
- Malaysian items (AES/AwAS alerts, toll estimate, railway crossings, Shell/Liberty/Selangor partnerships) come from Malaysian tech press, not Waze.
