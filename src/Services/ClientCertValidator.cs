using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Services;

public sealed class ClientCertValidator
{
    private const string ClientAuthEku = "1.3.6.1.5.5.7.3.2";

    public enum DeviceIdBinding { Disabled, SubjectCN, SanDns, SanUri, Thumbprint, Auto }

    private readonly HashSet<string> _trustedCaThumbprints;
    private readonly HashSet<string> _allowedLeafThumbprints;
    private readonly List<X509Certificate2> _rootStore;          // anchors: CustomTrustStore
    private readonly List<X509Certificate2> _intermediateStore;  // path hints: ExtraStore only
    private readonly Dictionary<string, string> _thumbprintToDeviceMap;
    private readonly bool _checkRevocation;
    private readonly X509RevocationMode _revocationMode;
    private readonly X509RevocationFlag _revocationFlag;
    private readonly bool _requireClientAuthEku;
    private readonly bool _required;
    private readonly bool _trustForwardedHeader;
    private readonly DeviceIdBinding _deviceBinding;
    private readonly ILogger<ClientCertValidator> _log;

    public ClientCertValidator(IConfiguration cfg, ILogger<ClientCertValidator> log)
    {
        _log = log;

        _trustedCaThumbprints = ParseCsv(cfg["ClientCert:TrustedCaThumbprints"])
            .Select(NormalizeThumbprint)
            .Where(t => t.Length > 0)
            .ToHashSet();

        _allowedLeafThumbprints = ParseCsv(cfg["ClientCert:AllowedLeafThumbprints"]
                ?? cfg["ClientCert:AllowedThumbprints"])
            .Select(NormalizeThumbprint)
            .Where(t => t.Length > 0)
            .ToHashSet();

        _rootStore = new List<X509Certificate2>();
        _intermediateStore = new List<X509Certificate2>();

        // Preferred: explicit root vs intermediate split (only roots become trust anchors).
        LoadCerts(cfg["ClientCert:TrustedRootCertificates"], _rootStore, "root");
        LoadCerts(cfg["ClientCert:TrustedIntermediateCertificates"], _intermediateStore, "intermediate");

        // Backward compatibility: legacy TrustedCaCertificates entries are auto-classified by
        // inspecting Subject==Issuer (self-signed => root, otherwise => intermediate). This
        // preserves the previous "everything is an anchor" behaviour for self-signed roots
        // while preventing intermediates from being silently elevated to trust anchors.
        var legacyRaw = cfg["ClientCert:TrustedCaCertificates"];
        if (!string.IsNullOrWhiteSpace(legacyRaw))
        {
            _log.LogWarning(
                "ClientCert:TrustedCaCertificates is deprecated. " +
                "Use TrustedRootCertificates (anchors) and TrustedIntermediateCertificates (path hints) instead.");

            foreach (var b64 in ParseCsv(legacyRaw))
            {
                var ca = TryLoadCert(b64);
                if (ca is null) continue;
                var isSelfSigned = string.Equals(ca.Subject, ca.Issuer, StringComparison.OrdinalIgnoreCase);
                if (isSelfSigned)
                {
                    _rootStore.Add(ca);
                    _log.LogInformation("Legacy CA classified as ROOT (self-signed): {Subject}", ca.Subject);
                }
                else
                {
                    _intermediateStore.Add(ca);
                    _log.LogInformation("Legacy CA classified as INTERMEDIATE: {Subject}", ca.Subject);
                }
            }
        }

        _checkRevocation = bool.TryParse(cfg["ClientCert:CheckRevocation"], out var cr) && cr;
        _revocationMode = Enum.TryParse<X509RevocationMode>(cfg["ClientCert:RevocationMode"], true, out var rm)
            ? rm
            : (_checkRevocation ? X509RevocationMode.Online : X509RevocationMode.NoCheck);
        _revocationFlag = Enum.TryParse<X509RevocationFlag>(cfg["ClientCert:RevocationFlag"], true, out var rf)
            ? rf
            : X509RevocationFlag.ExcludeRoot;

        _requireClientAuthEku = !bool.TryParse(cfg["ClientCert:RequireClientAuthEku"], out var eku) || eku;
        _required = !bool.TryParse(cfg["ClientCert:RequireClientCert"], out var r) || r;
        _trustForwardedHeader = bool.TryParse(cfg["ClientCert:TrustForwardedHeader"], out var th) && th;
        _deviceBinding = Enum.TryParse<DeviceIdBinding>(cfg["ClientCert:DeviceIdBindingClaim"], true, out var db)
            ? db
            : DeviceIdBinding.Auto;

        // Operator-maintained mapping: cert thumbprint -> EntraDeviceId.
        // Format: "THUMB1=guid1|THUMB2=guid2" (separators , ; | accepted). Whitespace ignored.
        // Used by Thumbprint binding mode and as final fallback for Auto mode. This is the
        // PKI-neutral escape hatch when the certificate Subject does not embed the device id.
        _thumbprintToDeviceMap = new(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in ParseCsv(cfg["ClientCert:ThumbprintToDeviceMap"]))
        {
            var eq = pair.IndexOf('=');
            if (eq <= 0 || eq == pair.Length - 1) continue;
            var thumb = NormalizeThumbprint(pair[..eq]);
            var devId = pair[(eq + 1)..].Trim();
            if (thumb.Length == 0 || devId.Length == 0) continue;
            if (!Guid.TryParse(devId, out var g))
            {
                _log.LogWarning("ThumbprintToDeviceMap entry skipped: '{DeviceId}' is not a GUID (thumb={Thumb}).", devId, thumb);
                continue;
            }
            _thumbprintToDeviceMap[thumb] = g.ToString();
            _log.LogInformation("Loaded thumbprint->device mapping: {Thumb} -> {DeviceId}", thumb, g);
        }
    }

    private void LoadCerts(string? csv, List<X509Certificate2> target, string label)
    {
        if (string.IsNullOrWhiteSpace(csv)) return;
        foreach (var b64 in ParseCsv(csv))
        {
            var ca = TryLoadCert(b64);
            if (ca is null) continue;
            if (string.Equals(label, "root", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(ca.Subject, ca.Issuer, StringComparison.OrdinalIgnoreCase))
            {
                _log.LogWarning(
                    "Certificate in TrustedRootCertificates is NOT self-signed (Subject='{Subject}', Issuer='{Issuer}'). " +
                    "It will be used as a trust anchor anyway, but consider moving it to TrustedIntermediateCertificates.",
                    ca.Subject, ca.Issuer);
            }
            target.Add(ca);
            _log.LogInformation("Loaded {Label} CA: {Subject} (thumb={Thumb})", label, ca.Subject, ca.Thumbprint);
        }
    }

    private X509Certificate2? TryLoadCert(string b64)
    {
        try
        {
            var bytes = Convert.FromBase64String(StripPem(b64));
            return X509CertificateLoader.LoadCertificate(bytes);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to load configured trusted CA certificate (skipped)");
            return null;
        }
    }

    /// <summary>
    /// Validates the client certificate. Returns (ok, cert, reason).
    /// </summary>
    public (bool Ok, X509Certificate2? Cert, string? Reason) Validate(HttpContext ctx)
    {
        if (_trustedCaThumbprints.Count == 0 && _rootStore.Count == 0)
        {
            _log.LogError("ClientCertValidator misconfigured: no TrustedCaThumbprints, no TrustedRootCertificates, and no legacy TrustedCaCertificates. Failing closed.");
            return (false, null, "client certificate trust anchor not configured");
        }

        X509Certificate2? cert = ctx.Connection.ClientCertificate;

        if (cert is null && _trustForwardedHeader
            && ctx.Request.Headers.TryGetValue("X-ARR-ClientCert", out var header))
        {
            try
            {
                var raw = StripPem(header.ToString());
                if (!string.IsNullOrEmpty(raw))
                {
                    var bytes = Convert.FromBase64String(raw);
                    cert = X509CertificateLoader.LoadCertificate(bytes);
                }
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Failed to parse X-ARR-ClientCert header");
            }
        }

        if (cert is null)
            return (!_required, null, _required ? "client certificate missing" : null);

        var now = DateTime.UtcNow;
        if (now < cert.NotBefore.ToUniversalTime() || now > cert.NotAfter.ToUniversalTime())
            return (false, cert, "certificate expired or not yet valid");

        if (_requireClientAuthEku && !HasClientAuthEku(cert))
            return (false, cert, "certificate missing Client Authentication EKU (1.3.6.1.5.5.7.3.2)");

        if (_allowedLeafThumbprints.Count > 0)
        {
            var leafTp = NormalizeThumbprint(cert.Thumbprint ?? string.Empty);
            if (!_allowedLeafThumbprints.Contains(leafTp))
                return (false, cert, "leaf certificate thumbprint not in allow-list");
        }

        using var chain = new X509Chain();
        chain.ChainPolicy.RevocationMode = _checkRevocation ? _revocationMode : X509RevocationMode.NoCheck;
        chain.ChainPolicy.RevocationFlag = _revocationFlag;
        chain.ChainPolicy.VerificationTime = now;
        chain.ChainPolicy.UrlRetrievalTimeout = TimeSpan.FromSeconds(15);

        if (_rootStore.Count > 0)
        {
            // Only ROOT certs become trust anchors. Intermediates go only to ExtraStore
            // so the chain builder can discover them, but they cannot be used as anchors.
            chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            chain.ChainPolicy.CustomTrustStore.AddRange(_rootStore.ToArray());
            chain.ChainPolicy.ExtraStore.AddRange(_rootStore.ToArray());
            if (_intermediateStore.Count > 0)
                chain.ChainPolicy.ExtraStore.AddRange(_intermediateStore.ToArray());
        }
        else if (_intermediateStore.Count > 0)
        {
            // No custom roots configured: fall back to the machine trust store (System trust)
            // and just hint the chain builder with the known intermediates.
            chain.ChainPolicy.ExtraStore.AddRange(_intermediateStore.ToArray());
        }

        var built = chain.Build(cert);
        if (!built)
        {
            var reasons = string.Join("; ",
                chain.ChainStatus.Select(s => $"{s.Status}: {s.StatusInformation.Trim()}"));
            return (false, cert, $"certificate chain build failed ({reasons})");
        }

        if (_trustedCaThumbprints.Count > 0)
        {
            var chainThumbs = chain.ChainElements
                .Cast<X509ChainElement>()
                .Skip(1) // exclude leaf
                .Select(e => NormalizeThumbprint(e.Certificate.Thumbprint ?? string.Empty))
                .ToHashSet();

            if (!_trustedCaThumbprints.Overlaps(chainThumbs))
                return (false, cert, "no trusted CA thumbprint found in the certificate chain");
        }

        return (true, cert, null);
    }

    private static bool HasClientAuthEku(X509Certificate2 cert)
    {
        foreach (var ext in cert.Extensions.OfType<X509EnhancedKeyUsageExtension>())
        {
            foreach (var oid in ext.EnhancedKeyUsages)
                if (oid.Value == ClientAuthEku) return true;
        }
        return false;
    }

    /// <summary>
    /// Extracts the device identifier the certificate is bound to, according to the configured binding claim.
    /// Returns null when binding is Disabled or the claim is not present.
    /// </summary>
    public string? GetBoundDeviceId(X509Certificate2 cert)
    {
        switch (_deviceBinding)
        {
            case DeviceIdBinding.Disabled:
                return null;

            case DeviceIdBinding.SubjectCN:
                return ExtractFromSubject(cert);

            case DeviceIdBinding.SanDns:
                return FirstSanValue(cert, X509NameType.DnsName);

            case DeviceIdBinding.SanUri:
                return FirstSanValue(cert, X509NameType.UrlName);

            case DeviceIdBinding.Thumbprint:
                return LookupByThumbprint(cert);

            case DeviceIdBinding.Auto:
                // Operator-maintained mapping wins when populated for this cert (explicit intent),
                // otherwise try every PKI convention in order. PKI-agnostic: customers don't have
                // to change their cert templates, and the operator can override on a per-cert basis.
                return LookupByThumbprint(cert)
                    ?? FirstSanValue(cert, X509NameType.UrlName)
                    ?? FirstSanValue(cert, X509NameType.DnsName)
                    ?? ExtractFromSubject(cert);

            default:
                return null;
        }
    }

    public bool BindingEnabled => _deviceBinding != DeviceIdBinding.Disabled;

    private string? LookupByThumbprint(X509Certificate2 cert)
    {
        var thumb = NormalizeThumbprint(cert.Thumbprint ?? string.Empty);
        return thumb.Length > 0 && _thumbprintToDeviceMap.TryGetValue(thumb, out var devId) ? devId : null;
    }

    private static string? ExtractFromSubject(X509Certificate2 cert)
    {
        // Prefer the leaf CN, but fall back to scanning the full DN for any GUID-shaped value
        // (covers customer PKIs that put the device id in OU=, DC=, serialNumber=, etc.).
        var cn = cert.GetNameInfo(X509NameType.SimpleName, false);
        var fromCn = string.IsNullOrWhiteSpace(cn) ? null : ExtractGuid(cn);
        if (fromCn is not null) return fromCn;
        return string.IsNullOrWhiteSpace(cert.Subject) ? null : ExtractGuid(cert.Subject);
    }

    private static string? FirstSanValue(X509Certificate2 cert, X509NameType nameType)
    {
        var v = cert.GetNameInfo(nameType, false);
        return string.IsNullOrWhiteSpace(v) ? null : ExtractGuid(v);
    }

    private static string? ExtractGuid(string raw)
    {
        // Accept the raw value if it's already a GUID, otherwise try to extract one.
        if (Guid.TryParse(raw.Trim(), out var g)) return g.ToString();
        var m = System.Text.RegularExpressions.Regex.Match(raw,
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
        return m.Success ? m.Value : null;
    }

    private static IEnumerable<string> ParseCsv(string? value)
        => (value ?? string.Empty)
            .Split(new[] { ',', ';', '|' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .Where(s => s.Length > 0);

    private static string NormalizeThumbprint(string t)
        => new string(t.Where(c => !char.IsWhiteSpace(c) && c != ':').ToArray()).ToUpperInvariant();

    private static string StripPem(string s)
        => s.Replace("-----BEGIN CERTIFICATE-----", string.Empty)
            .Replace("-----END CERTIFICATE-----", string.Empty)
            .Replace("\r", string.Empty)
            .Replace("\n", string.Empty)
            .Trim();
}
