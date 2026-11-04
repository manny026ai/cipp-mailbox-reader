# CIPP mailbox evidence reader

Local distribution proposal. Repository creation, public source sharing, package publication and installation require separate owner approval. This packet performs none of them.

This additive provider overlay introduces `GET /api/ListMailboxPermissionEvidence` under the existing `Exchange.Mailbox.Read` role. It preserves the legacy permission endpoint. Four native reads retain mailbox/subject identity, native Send As entries and completeness witnesses. Direct observations do not establish effective access, approval or permission to change access. Existing CIPP authorization and token custody remain in control.

Modification notice, 2026-11-03: this independently maintained overlay adds the two provider functions, the structured operation/profile and the pinned module-build recipe. Preserve upstream notices and the unmodified GNU AGPLv3 text in `LICENSE.upstream.md`. The official upstream project is [CyberDrain/CIPP](https://github.com/CyberDrain/CIPP).

## Contents and fixed inputs

The companion source has exactly eight tracked files: this README, one manual workflow, two provider functions, the OpenAPI operation, Dockerfile overlay, context-preparation script and upstream license. It contains no consuming application, integration credentials, customer configuration or internal tests. Do not copy an application's checkout into this repository.

| Input | Exact value |
| --- | --- |
| Upstream source | `CyberDrain/CIPP` at `8971c3fc6601fdfd30a9a31b35cffdb1ab67163b` |
| Runtime base | `ghcr.io/cyberdrain/cipp@sha256:d03570ebcaf189df85e5b64497a40861ff3ab320e7ee1c90ec4c5b082a4c8b72` |
| Build SDK | `ghcr.io/cyberdrain/dotnet/sdk@sha256:6ba9644da07bb5b560a402acec9ca38711a0762969f1b61da261df5c9f6f85da` |
| Platform | `linux/amd64` |
| Proposed companion repository | `manny026ai/cipp-mailbox-reader` |
| Fixed package destination | `ghcr.io/manny026ai/cipp-mailbox-reader` |

The SDK/runtime references are immutable digests. Updating CIPP requires a new source/base/build review. Do not substitute a changing tag or an unrelated upstream repository.

## Build locally or on an approved runner

Use Docker with Buildx, Git and PowerShell 7. No application or tenant credential is required. Fetch a clean official upstream checkout at the exact commit above. From this companion's root, run:

```powershell
./prepare-context.ps1 -OfficialSourceRoot /path/to/clean-official-cipp -OutputRoot /path/to/new-empty-context
```

The output must be new/empty and outside the upstream checkout. The script copies only the pinned official module sources/build tools, applies the overlay in that separate context and emits the profile/spec/manifests. It does not edit the upstream checkout or copy this whole repository. The Dockerfile compiles the two modules with upstream's vendored build tools, validates syntax/exports/HTTP role metadata, and overlays the compiled modules/specs onto the fixed runtime base.

Read `readerProfileId` from the context's `context-manifest.json`, then run:

```sh
docker buildx create --name cipp-mailbox-reader --driver docker-container --use
docker buildx inspect cipp-mailbox-reader --bootstrap
docker buildx build --builder cipp-mailbox-reader --platform linux/amd64 --provenance=false --sbom=false \
  --build-arg READER_PROFILE_ID=PROFILE_ID_FROM_MANIFEST \
  --load --tag cipp-mailbox-reader:reviewed /path/to/new-empty-context
```

The runtime is non-root/distroless. No final-stage shell or runtime upgrade is introduced. The profile is generated after provider/schema bytes exist; an image cannot embed its own final registry digest in itself.

## Proposed manual GitHub workflow

The workflow has no push, pull-request, release or schedule trigger. It accepts an exact reviewed companion commit and defaults `publish` to false. It also checks that the dispatched source/workflow commit matches that ref and that only the eight allowed files are tracked.

The read-only build job produces a Docker image archive, a build record, the generated profile/context manifest, and two source archives (the exact companion tree and exact public upstream tree). A review artifact, subject to the repository's access controls, is retained for one day. This retention is for review, not a durable source offer. The build runs no provider instance, Microsoft request, customer lookup or consuming application. Both build recipes explicitly bootstrap and bind a `docker-container` worker rather than relying on the runner's default Docker driver.

After a successful private build and a separate approved sharing/source-access decision, an owner may explicitly dispatch with `publish=true`. That run's publication job loads and hashes the exact image saved by its build job; it does not rebuild it. Publication uses the official Docker login action and the job's ephemeral `GITHUB_TOKEN`, limited to `packages:write` plus repository read. No PAT, long-lived registry password, app credential or new registry service is required. Checkout credentials are not persisted; no credential is passed into the Docker context/image. The build job has no package-write permission.

The package path is fixed. Tags contain the reviewed commit/run/attempt; no rolling `latest` tag is written. The publication workflow does not create a repository, change package visibility, publish source release assets, change a hosting application or install the provider. A namespace already owned by an unlinked package may reject this workflow token. Stop and have the owner review package/repository linkage; do not fall back to a PAT.

GitHub Actions/storage and registry usage still use the account's quotas. Review those before dispatch; this proposal creates no new paid registry and makes no zero-cost guarantee. There are no automatic retries.

## Source availability before distribution or service exposure

Preserve the six provider files and their notices, the build recipe, the exact companion source archive, the exact upstream source archive, generated profile/manifest and checksums. Record the companion commit and upstream/base/SDK digests next to the published image digest. The archive pair plus recipe lets a recipient reconstruct the overlaid CIPP source and the reviewed build inputs; retain all applicable inherited notices.

Before image distribution, the owner must choose and verify durable corresponding-source access for recipients. An approved ordinary GitHub release can hold both source archives and checksums, with clear links next to the package. One-day Actions artifacts alone are insufficient for that handoff. Verify coverage for inherited runtime/base components and their applicable licenses before claiming the source package is complete.

For remote use of the modified service, the owner must also choose and verify the prominent source-offer mechanism for its users. This overlay does not add a source-offer UI or endpoint. A public repository by itself is not proof that the installed service presents the required offer. See sections 6 and 13 of the [exact upstream AGPLv3 license](https://github.com/CyberDrain/CIPP/blob/8971c3fc6601fdfd30a9a31b35cffdb1ab67163b/LICENSE.md). The proposal does not make a compliance ruling, post to the vendor, accept a CLA or publish anything.

Repository visibility, source-asset access and package visibility are separate owner decisions. If anonymous package pulls are chosen, verify an unauthenticated pull by the final digest after that visibility decision. A private-package hosting credential is outside this proposal; do not invent or copy one to make installation work.

## Verify and pin a published image

The publication job records the registry's `sha256` digest, pulls that exact reference and checks its image configuration against the saved build. The deployment reference must have this form:

```text
ghcr.io/manny026ai/cipp-mailbox-reader@sha256:REGISTRY_MANIFEST_DIGEST
```

Do not substitute a tag, Docker configuration ID, archive checksum or reader profile ID for the registry manifest digest. Each identifies a different object. Root/owner review must additionally bind the actual fetched image to its compiled modules, profile/spec/compressed-file hashes, source/base/SDK inputs and source-access records before installation. A read-only extraction using `docker create` and `docker cp` can inspect image files without starting the provider.

Record and retain the previous runtime digest for rollback. Image publication is not authorization for installation, role grants, activation, live reads or permission changes. Later runtime/permission/consumer acceptance requires its own reviewed receipts.
