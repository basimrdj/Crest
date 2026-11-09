# Payment Autofill Security Architecture & Threat Model

**Author:** Browser Security Architect & Principal Browser Engineer
**Status:** Security specification and gated implementation design (non-PAN storage baseline)
**Applicability:** Crest Browser (macOS, iOS, iPadOS)

---

## 1. Executive Summary

Crest's native autofill system handles reusable identity and address records for daily browsing. This document evaluates the technical feasibility, threat landscape, and platform constraints of introducing **Payment Card Autofill** into Crest.

Based on our threat modeling, platform security analysis, and strict compliance boundaries:
1. **CVV/CVC codes must NEVER be stored, logged, or cached under any circumstances.** This adheres strictly to the Payment Card Industry Data Security Standard (PCI DSS Requirement 3.2), which explicitly prohibits retaining card verification values after transaction authorization.
2. **Primary Account Number (PAN) storage is gated behind explicit macOS Device-Owner Biometrics / Secure Enclave Keychain protection.**
3. **No automatic background injection or silent release.** Payment card details may only be released following an explicit user gesture on an authenticated, validated top-level HTTPS origin.
4. Because shipping an incomplete or speculative payment vault presents severe security risks to users, Crest ships **Identity and Address Autofill** as its primary production deliverable, while establishing this formal security specification as the prerequisite gate before PAN storage can be unlocked.

---

## 2. Threat Modeling & Attack Surfaces

### 2.1 Malicious Web Pages & Form Phishing
- **Threat:** A deceptive website presents hidden, off-screen, or opacity-zero payment fields to trick the browser into harvesting the user's card data when filling an apparently benign form (e.g., newsletter signup).
- **Control:**
  - Payment fields are never filled alongside standard address or identity fields.
  - An element must satisfy strict visibility criteria: bounding client rect dimensions > 0, opacity > 0, display != none, visibility != hidden, and must reside inside the visible viewport.
  - Payment suggestions require dedicated user selection separate from address identities.

### 2.2 Cross-Origin iframes & Embedded Third-Party Contexts
- **Threat:** An untrusted third-party iframe (e.g., ad network or widget) attempts to capture cardholder data on an otherwise legitimate merchant website.
- **Control:**
  - Autofill release is strictly bound to the top-level document's verified HTTPS origin.
  - If a payment form resides in an iframe, the iframe must possess an ancestor origin matching the top-level origin or explicitly declare `allow="payment"` in compliance with the W3C Payment Request / Permissions Policy specifications.

### 2.3 Compromised Extensions & Content Scripts
- **Threat:** A rogue Chromium extension or injected script attempts to read filled card numbers from input DOM elements or intercept keystrokes.
- **Control:**
  - Content bridges in Crest operate in an **isolated world** (`BrowserPageContentScripting` on Chromium and isolated user scripts on WebKit) that untrusted page scripts and extensions cannot directly access or prototype-pollute.
  - Digital wallet standards (Apple Pay via WebKit / Payment Request API) are favored over raw DOM input manipulation where available.

### 2.4 Device & System Boundaries
- **Threat:** Malware running with local user permissions attempts to read stored card details from disk or application memory.
- **Control:**
  - Cardholder data (PAN, expiration month/year, cardholder name) is encrypted using the macOS Keychain with `kSecAccessControlBiometryAny` and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  - Decrypted card data is held only in ephemeral memory within a zeroizing lease wrapper (`SecureBuffer`), cleared immediately upon injection or cancellation.
  - In normal UI, only masked card numbers (last 4 digits, e.g. `•••• •••• •••• 4242`) are ever presented. Full PAN is never visible in plaintext without re-authenticating via Touch ID or system password.

---

## 3. Data Lifecycle & Policy Boundaries

| Attribute | Storage Location | Retention Policy | Exportable? | Synced via iCloud? |
| :--- | :--- | :--- | :--- | :--- |
| **Cardholder Name** | macOS Keychain | User deleted or Space deleted | No | Optional (End-to-End Encrypted) |
| **PAN (Card Number)**| Keychain (Biometric Gated) | User deleted or Space deleted | No | Optional (End-to-End Encrypted) |
| **Expiration Date** | macOS Keychain | User deleted or Space deleted | No | Optional (End-to-End Encrypted) |
| **CVV / CVC** | **PROHIBITED** | **NEVER STORED** | **NEVER** | **NEVER** |
| **Card Nickname** | Keychain Attribute | User deleted or Space deleted | No | Yes |

---

## 4. Multi-Engine Parity: WebKit & Chromium

- **WebKit (macOS & iOS):** Leverages WKUserScript in isolated worlds with direct security origin validation against `WKSecurityOrigin`.
- **Chromium (macOS):** Requires coordination with Crest's host overlay. Raw Chromium Autofill services communicate through CEF / Chromium engine ports. If native Chromium autofill UI hooks are unavailable without engine rebuilds, the isolated world content script bridge ensures uniform behavior across both engines.

---

## 5. Implementation Gate Criteria for Phase C

Before PAN storage can be enabled in production:
1. Complete peer security review of Keychain access control wrappers.
2. Integration of LocalAuthentication biometric prompts (`LAContext`) with graceful fallbacks for hardware without Touch ID.
3. Verification that memory dumps or crash logs never retain cardholder records.
4. Acceptance by the upstream Crest maintainer of the cryptographic and storage boundaries.
