# AK Wallet (iOS 17+)

A SwiftUI OpenID4VCI / OpenID4VP / ISO 18013-5 wallet built on **AKSecurity**, **AKOpenID4VCI** and **AKPresentation**.

## Build

The project expects the packages next to it:

```
~/Projects/AKSecurity/AKSecurity
~/Projects/AKOpenID4VCI
~/Projects/AKPresentation
~/Projects/AKWallet
```

```bash
brew install xcodegen
cd ~/Projects/AKWallet
xcodegen
open AKWallet.xcodeproj
```

Choose your team under Signing & Capabilities, then run it on a device. The Simulator has no Secure Enclave, camera or Bluetooth, so it falls back to software keys and pasted links.

## Features

**Issuance (OpenID4VCI 1.1)**
- Credential offers by QR code, deep link (`openid-credential-offer://`, `haip-vci://`) or a pasted link.
- Wallet-initiated issuance: paste a Credential Issuer URL.
- Pre-Authorized Code flow, including transaction code entry.
- Authorization Code flow: Interactive Authorization (with an in-wallet OpenID4VP presentation step) when the server supports it, otherwise the system browser via ASWebAuthenticationSession.
- DPoP, batch issuance (configurable number of copies) and deferred issuance.
- Formats: SD-JWT VC, mdoc, W3C VC (JWT and Data Integrity).
- Every credential is verified before it is stored, and the result is shown on the card.

**Storage**
- Credentials are kept in an AES-GCM encrypted file. The key is in the Keychain (this device only).
- ES256 holder keys are generated in the Secure Enclave. Other algorithms use software keys in the Keychain.
- Each presentation uses the least-used copy of a credential, which limits linkability.

**Presentation**
- OpenID4VP 1.0 with DCQL, from QR codes or `openid4vp://`, `haip-vp://`, `eudi-openid4vp://` and `mdoc-openid4vp://` links.
- The consent screen shows verifier trust, transaction data, the credential chosen for each query and the requested claims.
- ISO/IEC 18013-5 proximity under the Share tab: QR engagement or NFC tap, BLE peripheral server or central client mode, reader authentication, and a choice of elements per document.
- Optional Face ID before anything is shared.

## Trust setup (Settings)

- Add PEM trust anchors for credential issuers, mdoc IACAs, OpenID4VP verifiers and mdoc readers.
- **Development mode** is on by default. In this mode:
  - Credentials whose chain isn't anchored are still accepted and marked as untrusted. Signatures are always checked.
  - Unregistered verifiers are allowed.
- Turn development mode off for production.

## NFC engagement (Host Card Emulation)

1. Apple must grant the `com.apple.developer.nfc.hce` entitlement for your bundle id. It is currently available only in some regions, such as the EEA.
2. Point `CODE_SIGN_ENTITLEMENTS` at `AKWallet/AKWallet-HCE.entitlements`.
3. Set `AKNFCEngagementEnabled` to `true` in `project.yml`, then run `xcodegen` again.

Without these steps the Share tab offers QR engagement only.

## Known limitations

- The app has not been compiled in the environment where it was written. Expect to fix minor compile errors on the first build.
- Issuance sessions aren't persisted. Deferred polling and "Request fresh copies" only work while the app stays running.
- No wallet or key attestation backend is included. To add one, plug `walletAttestation` and `keyAttestationProvider` into `WalletService.vciWallet()`.
- `ldp_vc` credentials can be stored but not presented.
