# ShelfScan — Library Connection Roadmap

Companion to [`catalog-integration-plan.md`](./catalog-integration-plan.md), which
holds the gateway/DAIA architecture. This doc covers **how we actually get
connected** — what to ask whom, in what order, and what has to happen before the
app is published.

Status as of 2026-09-30: Phase 1 live. Nothing below is built yet.

---

## 1. Where we are

| Layer | File | State |
|---|---|---|
| Live connection | `lib/apollo_catalog_service.dart` | Working — Georgetown, in-app scraper |
| The seam | `lib/library_status_service.dart:20` | `final libraryStatus = ApolloLibraryStatusService();` |
| Multi-library design | `docs/catalog-integration-plan.md` | Design approved, not built |

The scraper uses Apollo's internal backend at
`catalog.georgetowntexas.gov/catalog/ajax_backend`:
`session_nonlogin.xml.pl` → `search_setup` → `perform_search` → `biblio_info`.

**No credentials involved.** `session_nonlogin` is an anonymous public session —
the same thing a patron's browser opens. Zero patron data touched. We have
Georgetown's informal blessing to use it (volunteer, own device).

---

## 2. The problem that forces the next step

Publishing changes the situation in three ways the original blessing didn't cover:

1. **Public repo.** The endpoint and the full request sequence become copyable by
   anyone. Abuse of Georgetown's catalog would no longer be traceable to us.
2. **App Store distribution.** Request volume scales with users, not with one
   person's phone.
3. **Apple Guideline 5.2.2** — apps accessing a third-party service must be
   permitted under that service's terms, and Apple may require the authorization
   be produced on request. Informal verbal permission is thin. Biblionix, whose
   software the endpoint actually is, has blessed nothing; Georgetown is their
   customer, not the API's owner.

### The load math nobody notices until it's live

Per book: 3 requests (`search_setup`, `perform_search`, `biblio_info`).
`book_scanner` runs them under `Future.wait`, so:

- A 20-book shelf = **~60 near-simultaneous requests from a single phone**
- Only the *session token* is cached (25 min). **Results are not cached at all.**
- 100 App Store users = thousands of uncoordinated bursts

From Georgetown's side that pattern looks like a small DoS. This is the most
likely way we get noticed and blocked.

### And one pinned string

```dart
static const _catalogVersion = '2026-01-16.01';
```

When Biblionix bumps the catalog version, the scraper breaks. **In the app, that
is a 1–2 week App Store review cycle with a dead demo. Behind a gateway, it is a
server deploy in minutes.** For a competition timeline this alone justifies the
gateway.

---

## 3. How Libby actually connects (the model to copy)

Not per-library — **vendor-to-vendor.**

OverDrive never negotiated with Georgetown's contractor. It negotiated once with
each *ILS vendor* and built the integration at that level. When a library signs
up, nothing is configured at the library; the two companies already did the work.
The library's step is consent plus identifying itself. That is why it feels like
"just put in a code."

Second reason it's seamless: **Apollo is cloud-hosted.** Every Biblionix library
runs on Biblionix infrastructure, not a server in the branch. There is no library
firewall in the path.

> **Correction to an earlier assumption:** IP allowlisting / static egress IP
> (Cloud NAT) is an **on-premise** ILS concern only. It does **not** apply to
> Georgetown or any cloud-hosted Apollo library. It only returns if we onboard a
> library running its own hardware. Earlier guidance over-generalized from SIP2.

**Implication:** the easy path is to ask the **vendor**, not the library. One
Biblionix arrangement covers every Apollo library in the country — hundreds of
small and mid-size US publics, exactly our target — with zero per-library IT.
This matters especially because Georgetown has no IT staff; they contract it out.

---

## 4. The plan: two tracks in parallel

### Track A — Biblionix (start now, slow, free to begin)

Long lead time, so it must not block anything.

**The ask:** enable read-only *item-status* access — NCIP or SIP2 — for our
gateway, across their tenants, for libraries that opt in. (`catalog-integration-plan.md`
already anticipates this: *"or NCIP once Biblionix enables it."*)

**Why we have a real shot:**
- Biblionix is **Austin-based** — essentially local to Georgetown.
- We are a **Georgetown volunteer with the library's blessing.** Having Georgetown
  ask on our behalf is worth vastly more than a cold student email. Vendors take
  "our customer wants this" seriously.

**Next move:** ask our Georgetown contact for an intro to their Biblionix rep, or
to file the request themselves.

**Unverified:** what Biblionix currently exposes. They may say no, want a
contract, or not have NCIP turned on at all. Needs the conversation.

### Track B — Minimal gateway (do now, before publishing)

Independent of Biblionix. Fixes the §2 problems on its own.

---

## 5. The minimal gateway

### What Georgetown's team must do technically: **nothing**

No credential, no account, no firewall change, no contractor, no software
install, no cost. There is nothing to provision because `session_nonlogin`
never required anything. Moving the code from phone to server changes none of it.

### What we do need from them — four conversational asks

1. **Written OK** (email is fine) covering the two changes: server-side access,
   and public App Store distribution. Name the endpoint. *This is the artifact
   App Store review can ask for under 5.2.2.*
2. **A rate limit they're comfortable with.** Let *them* name it, then implement
   it and tell them it's done. Costs them nothing; strongest trust signal
   available.
3. **A human to email when it breaks** — not IT, just someone who can relay to
   the Biblionix contractor (see the pinned `_catalogVersion`).
4. **The Biblionix intro** (Track A) — ask while already in the conversation.

### The pitch that makes it easy to say yes

The gateway **reduces** their load versus the status quo:

| | Today (in-app) | Behind gateway |
|---|---|---|
| Sessions | One per app install | One shared |
| Result caching | None | Short-TTL (juvenile titles repeat constantly) |
| Request pattern | ~60-request parallel spike per scan | Queued, rate-limited |
| Load with 100 users | Thousands of uncoordinated bursts | Predictable, capped |

Framing: *"I'm moving this off my phone onto a small server so it hits you less,
at a rate you set, and so the endpoint isn't sitting in a public repo for anyone
to copy."* Strictly better for them than what happens today.

### Our side — deliberately small

- **One Cloud Run service.** No Firestore, no Secret Manager, no static IP — all
  of that belongs to the credentialed multi-library version, not this.
- Port `apollo_catalog_service.dart` server-side roughly as-is.
- Add a **result cache** and a **rate limiter** (the two things that make the
  pitch above true).
- One revocable API key over TLS.
- Flip `library_status_service.dart:20` to `GatewayLibraryStatusService` —
  one line.
- **Delete the scraper from the app**, then publish.

After this the public repo contains a call to our own API with a revocable key —
no library hostname, no scraping logic, no endpoint to abuse.

---

## 6. Phase 2 proper — onboarding library #2+

Only needed once a second, credentialed library exists. Architecture lives in
`catalog-integration-plan.md`; the asks are here.

### Adapters are per-protocol, not per-library

~6 adapters cover most US public libraries (NCIP, SIP2, DAIA, Koha REST,
Alma/Sierra/Polaris REST). Library #1 and library #500 on Koha share one adapter.
Onboarding is a **config row, not a commit**, keyed by ISIL:

```json
{ "isil": "US-TxGeP", "ils": "apollo", "endpoint": "...", "cred_ref": "vault://..." }
```

### What each side does

**Biblionix (once):** enable read-only item-status access across tenants.

**A new library (~5 min, no IT):** say yes to their vendor, hand over their ISIL.
That's the code. The pitch becomes exactly what we want it to be — *"tell your
vendor you're opting in, give me your library code, and it works."*

### If a library is on-premise (the harder case)

Then it's credential + firewall, and the requests are:

- Hostname/IP and port (commonly 6001)
- SIP2 login user ID + password (an `SC` / self-check account)
- Institution ID and location code (`AO` / `AP` fields)
- Confirmation the account is **read-only, item status only**
- **Allowlist one IP address**

Framing that works: *"the same read-only self-check account you already
provisioned for Libby/OverDrive and your self-checkout machines."* The person
reading it has done it before.

Our strongest card: **zero patron PII, ever.** Item availability only; item-status
messages don't carry patron identity, so no personal data crosses any wire. This
routes around SIP2's known cleartext-PII problem — the exact objection a cautious
IT person raises.

**Requires static egress IP:** Cloud Run's default egress is dynamic, so there's
no single address to give them. Needs Direct VPC egress (or a VPC connector) plus
**Cloud NAT with a reserved static IP**. Do it once and the address is permanent,
which is what lets the ask stay "allowlist this one IP" forever.

> ⚠️ **Cost correction to `catalog-integration-plan.md`:** Cloud NAT is **not**
> free-tier. The claim "three managed pieces, all with free tiers" stops being
> true the moment a library IP-allowlists us. Small money, but a standing cost.
> Verify current GCP pricing before committing.

---

## 7. Sequencing

1. **Now —** start Track A (Biblionix intro via Georgetown). Slow, so start first.
2. **Now, in parallel —** send Georgetown the four asks in §5.
3. **Before publishing —** build the minimal gateway, flip the one line, strip the
   scraper from the app.
4. **Then —** publish the repo, submit to the App Store.
5. **When Biblionix says yes —** swap the Apollo adapter's guts server-side; every
   Apollo library lights up. **The app never changes.**
6. **Later —** self-service portal, auto-probe, remaining adapters.

## 8. Decisions and constraints

- **The Congressional App Challenge does not require any of this.** Phase 1 works.
  One library live plus a credible national-scale architecture is a *stronger*
  submission than a half-built gateway. The adapter table is the impressive part
  and it's already written. Keep Track A off the critical path.
- The minimal gateway is **not** about scale — it's so the public repo doesn't
  hand everyone a script that hammers Georgetown. Worth doing regardless of what
  Biblionix says, and it needs no vendor permission.
- No credentials ever shipped inside the app binary.
- No Firestore/Secret Manager/static IP until a second credentialed library exists.
- Accepted risk for the demo: the scraper depends on an undocumented internal
  Perl endpoint that can change without warning. That's the real argument for
  chasing sanctioned access — not the infrastructure.

## 9. Open items

- [ ] Georgetown: written OK for server-side + App Store distribution
- [ ] Georgetown: rate limit they want
- [ ] Georgetown: breakage contact
- [ ] Georgetown: Biblionix intro
- [ ] Biblionix: does NCIP/item-status API exist today? (unverified)
- [ ] Verify Cloud NAT pricing before any on-prem library onboarding
- [ ] Build minimal gateway + strip scraper **before** publishing repo

## References

- Apollo notes, incl. the per-copy vs. per-title barcode limitation: memory
  `library-ils-integration.md` (local to machine, **not in git**)
- DAIA spec: https://gbv.github.io/daia/
- ISIL (ISO 15511): https://en.wikipedia.org/wiki/International_Standard_Identifier_for_Libraries
- SIP2 security concerns: https://journals.ala.org/index.php/ltr/article/view/5974/7608
