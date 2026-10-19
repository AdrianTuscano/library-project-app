# Shelver Helper – Android demo (Kotlin + XML)

Native Android version of the Shelver Helper UI. No camera and no Claude: you type
the books on your shelf and it works out how to sort them.

Screens: **Sign in / Create account → Home (type your shelf) → Your shelf → What to do**, plus **Profile**.

## 1. Firebase setup (about 5 minutes, needs your Google account)

1. Go to <https://console.firebase.google.com> → **Add project** (any name, e.g. `shelver-helper`). Analytics can be off.
2. In the project, click the Android icon (**Add app**):
   - Package name: `com.shelverhelper.app` (must match exactly)
   - Skip the SHA-1 box. Click **Register app**.
3. **Download `google-services.json`** and put it in `android-demo/app/` (next to `app/build.gradle.kts`). Skip the "add SDK" steps; they're already done in this project.
4. **Authentication** → Get started → **Sign-in method** → enable **Email/Password**.
5. **Firestore Database** → Create database → pick a location → **Production mode**.
6. Firestore → **Rules** tab → paste the contents of [`firestore.rules`](firestore.rules) → **Publish**.

## 2. Run it

1. Android Studio → **Open** → choose the `android-demo` folder. Let Gradle sync (it downloads the SDK pieces it needs).
2. Device Manager → create a phone emulator (a "Google APIs" or "Google Play" image, API 34 is fine). The emulator needs internet for sign-in.
3. Press Run.

Demo flow: Create account → **Fill in a sample shelf** → **Sort my shelf** → tap spines → **What to do** → Back → **Profile** → change name/library → Save → Sign out.

## 3. Test the security rules (required by P2)

In the Firebase console → Firestore → Rules → **Rules Playground**:

| Test | Setup | Expected |
|---|---|---|
| Not signed in reads a profile | `get` `/users/abc`, Authenticated **off** | Denied |
| Signed in reads own profile | `get` `/users/abc`, Authenticated **on**, UID `abc` | Allowed |
| Signed in reads someone else's | `get` `/users/xyz`, UID `abc` | Denied |
| Writes someone else's | `update` `/users/xyz`, UID `abc` | Denied |
| Writes unknown field | `update` `/users/abc`, UID `abc`, data `{"displayName":"A","isAdmin":true}` | Denied |
| Reads any other collection | `get` `/books/1`, UID `abc` | Denied |

## Where things are

- `app/src/main/java/com/shelverhelper/app/`
  - `Models.kt` – text parsing and the sort logic (ported from `lib/shelf_sort_view.dart`)
  - `ShelfView.kt` – draws the spines, arcs and badges
  - `LoginActivity`, `HomeActivity`, `ResultsActivity`, `SortActivity`, `ProfileActivity`
  - `ProfileRepository.kt` – Firestore profile read/write
- `app/src/main/res/` – layouts, colors, icons (same gold / rust / spine palette as the iOS app)
- `firestore.rules`, `firebase.json` – security rules
