# Zuri Driver: setup guide for the GitHub sync

Rork allows one iOS app per project, so **Zuri Driver lives in its own Rork project**. Both apps share the
same backend (this project's `functions/`) so rides, chat and payouts line up.

## 1. Sync this passenger project to GitHub
1. In Rork, open this project → **GitHub** → connect and push. The repo contains `ios-twende/` (passenger
   iOS app), `functions/` (backend) and this guide.
2. Treat this repo as the **source of truth for the backend**. The driver project never deploys
   `functions/`; it only calls the backend URL.

## 2. Create the driver project
1. Create a new Rork project named **Zuri Driver** (native Swift).
2. Connect it to its **own** GitHub repo (e.g. `zuri-driver`). Don't point two Rork projects at the same
   repo, because each sync overwrites the other.
3. Copy these files from this repo into the driver app so the two apps look and talk the same:
   - `ios-twende/Twende/Theme/` (colours, Figtree fonts, button styles) and `ios-twende/Twende/Resources/Fonts/`
   - `ios-twende/Twende/Localization/` (Swahili default + English; trim passenger-only keys later)
   - `ios-twende/Twende/Models/` → `Trip.swift`, `Place.swift`, `GeoPoint.swift`, `RideTier.swift`, `FareQuote.swift`, `PaymentMethod.swift`
   - `ios-twende/Twende/Services/RideChatService.swift` (flip `sender` to `.driver`, remove `simulateDriverReply`)
   - `ios-twende/Twende/Views/Onboarding/OTPView.swift` (same phone-code screen)
   - `ios-twende/Twende/Components/SplitFlapBoard.swift`, `SplitFlapFace.swift`, `SplitFlapLeaf.swift` (ride PIN)
4. Give the driver app a different bundle ID (Rork does this automatically per project).

## 3. Backend URL for the driver app
```
https://passenger-app-full-build-specification-p-backend.rork.app
```
Hard-code it as a fallback like `PaymentGateway.baseURL` does in the passenger app. The driver project's
own `EXPO_PUBLIC_RORK_FUNCTIONS_URL` points at a *different*, empty backend, so don't use it.

## 4. Endpoints the driver app uses today
- `GET  /chat/<tripId>`: all chat lines `{messages:[{id,sender,original,language,sentAt}]}`
- `POST /chat/<tripId>`: send `{id, sender:"driver", original, language:"sw"|"en"}`
  - Each phone translates incoming lines into its own language (Rork Toolkit, Gemini Flash Lite).
  - Lines expire after 24 hours; 300 characters max, 200 lines per trip.
- `POST /payouts/preview` and `POST /payouts/create`: pay a driver to mobile money.
  - They need the `X-Zuri-Admin` header with `ZURI_ADMIN_KEY`, and should run from an operator tool, never from the driver's phone.
- `GET /ping`: health check.

## 5. What still has to be built on the backend (in THIS project)
Rides are simulated inside the passenger app right now. Before real two-app testing, add to `functions/`:
1. **Ride dispatch Durable Object** (one per trip): passenger `POST /rides` → drivers poll or WebSocket
   `GET /rides/open?near=lat,lng` → driver `POST /rides/<id>/accept` → status updates
   (`arrived`, `started` with the 4-digit ride PIN, `completed`).
2. **Driver location** `POST /drivers/<id>/location` every ~4 s while online; passengers read it for the map.
3. **Route changes**: when the passenger taps *Change route* → *Update route*, send the new stops and
   destination to `POST /rides/<id>/route` so the driver's navigation updates.
4. Replace `TripCoordinator`'s simulation in the passenger app with these calls. `RideChatService`
   already uses the real server, so chat works across both apps as soon as they share a trip id.

## 6. Keeping the two repos in step
- Change shared code (theme, models, localisation) in the passenger repo first, then copy it across.
  Keep a short `SHARED_FROM.md` in the driver repo with the passenger commit you copied from.
- Backend changes only ever go into this repo's `functions/`, then deploy from this Rork project.
- Test with two simulators or two phones: passenger build from this project, driver build from Zuri Driver.
