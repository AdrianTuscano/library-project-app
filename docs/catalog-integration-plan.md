# ShelfScan — Multi-Library Catalog Integration Plan

Status: **design approved, not yet built.** Georgetown runs on the in-app scraper
today; the gateway is deferred until a second, credentialed library appears.

## Goal

Let ShelfScan report real-time shelf availability for **any** library, with the
least possible work for us (developers) and for each library's catalog team.

## The core idea: a gateway as universal translator

The app speaks exactly one language — **DAIA** (an open availability standard).
It never knows what any library actually runs. A hosted gateway translates
DAIA ⇄ whatever that library's ILS speaks.

```
   App  ──DAIA/HTTPS + API key──▶  Gateway  ──▶  Library's ILS
 (dumb client,                   (translator +    (Apollo, Koha,
  one format)                     trust boundary)   Sierra, Alma…)
```

Result: canonical purity at the app layer, universal compatibility at the
library layer, at the same time.

## The insight that keeps the workload tiny

Adapters are written **per-protocol, not per-library.** The ILS market is small
and consolidated, so ~6 adapters cover the vast majority of US public libraries:

| Adapter (write once) | Covers |
|---|---|
| NCIP | Biblionix Apollo (Georgetown), Ex Libris, many more |
| SIP2 | Near-universal — almost every ILS |
| DAIA | Anyone already standards-compliant |
| Koha REST | Every Koha library (big in public/school) |
| Alma / Sierra / Polaris REST | The major commercial vendors |

Onboarding a new library is a **config row, not a commit**:

```json
{ "isil": "US-TxAusPL", "ils": "koha", "endpoint": "...", "cred_ref": "vault://..." }
```

Library #1 and library #500 on Koha share the same adapter.

## Library codes — reuse ISIL (ISO 15511)

Every library already has an ISIL (e.g. Georgetown ≈ `US-TxGeP`). Reusing it
means standards compliance out of the gate, public/scalable, no private
namespace to maintain. A hosted registry maps `ISIL → adapter + endpoint`.

## Onboarding — least work for the catalog team

Self-service portal, after we approve the library (authorization on our end):

1. Log in
2. Pick ILS from a dropdown
3. Paste a **read-only credential** — the same thing they already give Libby /
   OverDrive / self-checkout. Routine request their vendor handles daily.
4. Auto-probe detects the protocol and pre-fills config
5. "Test Connection" → live

**Libby is the tell:** a library running Libby already has the SIP2 plumbing on
and staff who've provisioned this exact kind of credential before. Not an
automatic join, but onboarding takes ~10 minutes.

## Security (Congressional App Challenge angle)

- Library credentials live **server-side, encrypted at rest, per-tenant.
  Never in the app.** (Embedding them would make them extractable from the
  binary — the vulnerability the gateway exists to prevent.)
- App holds only a **revocable API key** over TLS. It's a dumb client;
  compromising it exposes nothing but public availability data.
- **Zero patron PII, ever.** We pull only *item* availability. Item-status
  messages don't require patron identity, so no personal data crosses any wire.
  Deliberate threat-model choice — routes around SIP2's known cleartext-PII flaw.
- Gateway is the single trust boundary: rate-limited, auditable.
- Short-TTL availability cache protects libraries from being hammered.

## Infrastructure (when we build it): GCP

Reuse the existing GCP project (already used for Cloud Vision OCR). Three
managed pieces, all with free tiers:

| Need | GCP service |
|---|---|
| The gateway | Cloud Run (containers, scales to zero, cheap) |
| Library registry | Firestore |
| Library credentials | Secret Manager |

Cloud Run handles SIP2 fine — those connections are **outbound** (gateway →
library), which Cloud Run allows freely. No raw inbound TCP needed.

## The app is already gateway-ready

`lib/library_status_service.dart` defines the seam:

```dart
abstract class LibraryStatusService {
  Future<LibraryStatus> checkByIsbn(String isbn);
  Future<LibraryStatus> checkByTitle(String title, String author);
}

final libraryStatus = ApolloLibraryStatusService(); // scraper, for now
```

The future gateway is a new class — `GatewayLibraryStatusService implements
LibraryStatusService` — that does one HTTPS call and returns the same
`LibraryStatus`. Swapping to it is **one line**; the rest of the app is untouched.

## Phased plan

1. **Now (demo):** keep the in-app Apollo scraper as the live provider. Demo
   Georgetown. No cloud, no cost, no ops. ← current state
2. **Gateway skeleton + first adapter:** stand up Cloud Run + Firestore, move
   Georgetown behind the gateway (scraper server-side, or NCIP once Biblionix
   enables it), flip the app's one line to `GatewayLibraryStatusService`.
3. **Breadth:** SIP2 adapter + self-service onboarding portal + auto-probe.
4. **Coverage:** DAIA + Koha/Alma/Sierra adapters, library picker in the app
   (search by name → ISIL).

## Decisions locked in

- Scraper stays in the app for the current demo (no secrets involved, so safe).
- No infrastructure until a second, credentialed library exists — GCP is not
  required to reach the demo milestone.
- When the gateway is built, it goes on GCP (already there), not a new provider.
- No SIP2/NCIP credentials ever shipped inside the app.

## References

- DAIA spec: https://gbv.github.io/daia/
- ISIL (ISO 15511): https://en.wikipedia.org/wiki/International_Standard_Identifier_for_Libraries
- SIP2 security concerns: https://journals.ala.org/index.php/ltr/article/view/5974/7608
