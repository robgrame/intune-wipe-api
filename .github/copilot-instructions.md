# Repository instructions — intune-wipe-api

These instructions encode design rules and conventions that any contributor
(human or AI) must follow when working in this repository. They take
precedence over generic style preferences.

## Architecture: immutable core + plug-in capabilities

This service is structured as an **action-agnostic core** (HTTP intake,
dispatcher, queue infrastructure, status tracker, idempotency ledger, audit
plumbing) plus **self-contained capability plug-ins** (wipe, autopilot,
bitlocker, …).

**Hard rule: a new capability MUST integrate into the core without modifying
any core component.** "Core" here means the Shared project, the Web project,
the Proc dispatcher/router functions, and the existing capability projects.
Only the per-role composition root (`Proc/Program.cs`, and the new capability
host's own `Program.cs`) and the additive infra in `infra/main.bicep` are
expected to grow.

This rule applies whether or not the capability carries a payload of its own
on the wire — we have already paid the design cost to make payloads opaque to
the core (see "Capability-specific payloads" below). If you ever feel
tempted to add a capability-specific type, property, route, or branch to
Shared / Web / Proc, stop and re-design.

### What "the core" knows about a capability

The core knows ONLY:

- a stable action discriminator string (matches `IActionRunner.Type`); and
- that there is at least one `IActionRunner` registered in DI for that string.

The core never knows:

- the shape of any capability-specific payload;
- which Graph endpoint(s) the capability calls;
- which Entra groups, queues, storage accounts, or UAMIs it uses;
- which audit events the capability emits.

### Capability layout (copy the wipe / autopilot / bitlocker pattern)

A new capability `Foo` ships as:

- `src/Capabilities.Foo/` — class library project with:
  - `FooHostBuilderExtensions.cs` exposing `AddFooProbe`, `AddFooForwarding`,
    `AddFooExecutor` extension methods on `IServiceCollection`;
  - `Runners/FooForwardingRunner.cs` (`IActionRunner` registered on Proc; sends
    the envelope to the dedicated SB queue);
  - `Runners/FooRunner.cs` (`IActionRunner` registered on the executor host;
    performs the privileged work);
  - `Services/GraphFooService.cs` (thin wrapper on `GraphServiceClient` —
    capability-specific Graph calls);
  - `Services/FooActionStatusProbe.cs` (`IActionStatusProbe` for the poller);
  - `Senders/FooActionSender.cs` (wrapper around the `ServiceBusSender` for
    the dedicated queue);
  - `Audit/FooAuditEvents.cs` (capability-specific audit event constants);
  - `Models/` (any capability-specific payload/result types — never put these
    in Shared).
- `src/Foo/` — dedicated Function App host (privileged role) with a tiny
  `Program.cs` calling `services.AddFooExecutor()` plus the shared core, and
  one consumer function bound to the dedicated SB queue.

The composition root for the dispatcher (`src/Proc/Program.cs`) wires the
forwarder + probe with `services.AddFooForwarding(); services.AddFooProbe();`.
That is the **only** change permitted to existing core/host code.

`infra/main.bicep` grows additively (new UAMI, plan, storage, queue, role
assignments). Do not modify the existing wipe/proc/web blocks to make room
for a new capability.

### Capability-specific payloads

`ActionRequest` and `ActionRequestMessage` in Shared expose an opaque
`Extras` bag (`[JsonExtensionData] Dictionary<string, JsonElement>?`). Any
top-level JSON property on the request body that is not one of the four
core fields (`actionType`, `deviceName`, `entraDeviceId`, `intuneDeviceId`)
is captured automatically into `Extras` and forwarded end-to-end.

A capability that needs to carry data over the wire MUST:

- define its payload type inside its own capability project
  (`src/Capabilities.Foo/Models/FooPayload.cs`), never in Shared;
- expose a `public const string ExtrasKey = "foo"` on the payload so the
  contract between client and runner is owned by the capability;
- pull the element out of `Extras` in its runner and deserialize it itself.

The dispatcher envelope (`ActionDispatchMessage`) already carries the payload
as `JsonElement Payload`. Do not add typed capability fields to it.

### Allowlist

The HTTP intake gates `actionType` against the configured allowlist
(`Actions:AllowedTypes`, CSV). Enabling a new capability in an environment is
an App Configuration change, not a code change.

### Privilege isolation

Every privileged Graph capability runs on its own Function App with its own
user-assigned managed identity. Graph consent is granted on the app
registration per UAMI, never in Bicep, never cross-capability. The Proc app
must never hold a privileged Graph identity — it only forwards.

## Pre-production posture

Until v1.0 we accept breaking refactors of the core if they pay down
capability-coupling debt. The cost of changing core contracts later (after
real downstream clients exist) is much higher than now.

## Testing

- Build: `dotnet build src\IntuneDeviceActions.slnx -c Release`
- Client tests: `powershell.exe -NoProfile -File .\client\tests\Invoke-Tests.ps1`

Both must pass before merging changes that touch Shared, Web, Proc, or any
capability project.
