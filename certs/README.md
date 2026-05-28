# Trusted CA certificates

This folder holds the **public** (DER/PEM `.cer`) root and intermediate CA certificates that are baked into the API app settings via `infra/main.parameters.json`.

> ⚠️ Only public certificates (no private keys) belong here. Never commit `.pfx`, `.key`, or any private material.

## Current PKI (MSLABS)

| File | Subject | Role | Thumbprint |
|------|---------|------|------------|
| `ROOTCA.cer` | `CN=MSLABS-ROOTCA` | self-signed root → `ClientCert__TrustedRootCertificates` | `821340380E0AAF0053F5EFD3A5885B29365807CD` |
| `SubCA01.cer` | `CN=MSLABS-SUBCA01, DC=MSLABS, DC=LOCAL` | intermediate issued by ROOTCA → `ClientCert__TrustedIntermediateCertificates` | `A1BC56C613DB7C92E0E592794658BB2ECEBB4892` |

Both thumbprints are also added to the `ClientCert__TrustedCaThumbprints` allow-list (CSV) so that *only* client certs issued by these specific CAs are accepted.

## Onboarding a new PKI

1. Drop the new `.cer` files in this folder (DER or PEM, single cert per file).
2. Edit `infra/main.parameters.json`:
   - Append the base64 of each **self-signed** root to `trustedRootCertificatesBase64` (pipe-separated, no spaces).
   - Append the base64 of each **intermediate** to `trustedIntermediateCertificatesBase64`.
   - Append all thumbprints (uppercase, no separators) to `trustedCaThumbprints` (comma-separated).
3. Helper to compute base64 of a `.cer`:
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes('certs\NEWCA.cer'))
   ```
4. `azd deploy` (or `az deployment group create -g rg-intwipe-dev -f infra/main.bicep -p infra/main.parameters.json`).

## Design notes

The validator runs with `X509ChainTrustMode.CustomRootTrust`, so the OS root store is **disabled**. The complete chain must come from these certificates:

- `TrustedRootCertificates` → installed in CustomTrustStore (chain anchors)
- `TrustedIntermediateCertificates` → installed in ExtraStore (path hints, cannot be anchors)
- `TrustedCaThumbprints` → allow-list of acceptable issuing CAs (defense in depth)

See `src/Services/ClientCertValidator.cs` and `README.md` (ClientCert section) for full details.
