# Speaker attribution

The current live transcriber produces one timestamped text stream. Adding a
name to each turn requires evidence beyond the mixed application audio.

There are three different operations:

1. **Transcription:** what was said.
2. **Diarization:** which stretches sound like the same speaker, usually with
   anonymous labels such as `speaker-1` and `speaker-2`.
3. **Identity mapping:** evidence that `speaker-1` is a particular person.

A participant roster supplies candidate names, not a mapping of voices to
people. Names mentioned in a conversation are also insufficient by themselves.
A useful enrichment pipeline should preserve anonymous labels and uncertainty
until there is supporting evidence.

## What capture-it can supply

The WAV preserves app left/right and a separate microphone channel on a common
timeline. This gives an audio tool the option to analyze app playback separately
from microphone audio before combining results. The mic channel identifies an
input source, not necessarily one person: a room mic can contain several voices.
Application L/R are playback channels, not separate remote participants.

The optional FluidAudio hook produces anonymous turns. After capture, a listener
can name a detected voice and enroll it for future recordings. Matching runs
locally against confirmed examples. The original speaker IDs remain available
beside the identity evidence. [Setup and enrollment](fluid-audio-hook.md#remembered-voices).

## Getting names from the application

The most direct evidence would be an app-provided transcript that already
attributes turns, or timestamped speaker events tied to participant IDs.
Those would need an adapter for the app, permissions/account access where
required, and a mapping between the app's clock and the local recording timeline.

If an application exposes an active-speaker label through an accessibility
interface, a local adapter could collect timestamped observations. Availability
must be verified for each app/version. UI delay, multiple highlighted speakers,
overlap and incomplete accessibility labels make this supporting evidence rather
than a guaranteed voice-to-name mapping.

Teams, Slack and other apps are not assumed to expose a common local API for
speaker names. Capture-it reads audio/process/device information and selected-app
[window titles](meeting-metadata.md). It does not inspect meeting rosters, private
app databases, screens or accessibility contents for participant names. No
Teams/Slack speaker-name adapter is implemented.

## Verified options

Official documentation reviewed on 2026-11-18. These are documented capabilities,
not accuracy or performance benchmarks on this Mac. No provider was installed
or sent recordings during this research.

| Option | Speaker identity | Fit for capture-it |
| --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio#speaker-diarization) | Local diarization and speaker IDs; identity/enrollment depends on the chosen pipeline | Swift/Core ML. Its offline Community-1/VBx pipeline is a good candidate for an optional file-processing hook. Separate model assets are required; none are added to the core. |
| [pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) | Anonymous speaker turns | Python pipeline; can run offline after downloading assets. Model access requires accepting conditions and an access token. Multi-channel input is averaged to mono unless the hook prepares a different input. |
| [pyannoteAI identification](https://docs.pyannote.ai/tutorials/identification-with-voiceprints) | Can match speakers to supplied labeled reference voiceprints | Hosted API with an account/key. Needs known single-speaker reference audio; it cannot infer Teams identities from a roster alone. Audio leaves the Mac when this route is used. |
| [Teams Graph transcripts](https://learn.microsoft.com/en-us/graph/api/calltranscript-get?view=graph-rest-1.0) | Speaker-attributed WebVTT when allowed | Strong candidate for importing existing named turns. Requires a generated Teams transcript, Graph permissions and tenant policy allowing both API access and attribution. This is not a local tap into the Teams client. |
| [Slack huddle file metadata](https://docs.slack.dev/reference/objects/file-object/#transcription--huddle) | Participant IDs and transcript-related fields are documented | An import adapter could inspect an available huddle transcript. The reviewed schema does not establish a general live active-speaker feed or guarantee names on every returned turn. Verify actual accessible data in the target workspace. |
| [Recall desktop SDK](https://docs.recall.ai/docs/desktop-recording-sdk-faq) | Uses Accessibility for participant/speaker timeline metadata | A documented route to meeting-aware metadata. It is a separate SDK integration requiring live meeting observation, rather than a way to recover past UI state from a WAV. |

For Teams, Microsoft's [administrator controls](https://learn.microsoft.com/en-us/microsoftteams/meeting-transcript-api-access)
gate transcript API access and inclusion of speaker attribution independently.
The meeting resource also exposes a
[subject](https://learn.microsoft.com/en-us/graph/api/resources/onlinemeeting?view=graph-rest-1.0),
which could supply a title with an authenticated meeting lookup. Those cloud
permissions are separate from macOS Accessibility.

Slack's [`files.info`](https://docs.slack.dev/reference/methods/files.info/)
requires `files:read` and access to the relevant file. A transcript reference in
the schema does not guarantee every huddle has a generated, accessible transcript.
Recall's current [supported-platform matrix](https://docs.recall.ai/docs/dsdk-supported-platforms)
lists Teams meeting-title support on macOS and labels Slack Desktop support
audio-only. Treat its Teams support as a distinct option from Slack; do not
assume identical metadata coverage.

## Recommendation for this CLI

Keep Apple speech and native audio capture as the default. The optional local
FluidAudio hook supplies post-session speaker turns and voice matching. Evaluate
its results on representative meetings. This is a
project-fit recommendation based on its documented Swift/Core ML and file APIs,
not a claim that its accuracy is best. The hook must choose how to use app L/R
and the separate mic; automatic averaging is not always the desired mix.

For real names in Teams, prefer importing a speaker-attributed transcript when
the organization permits it. A local app-specific Accessibility speaker observer
is another integration to investigate, with Recall's documented approach as
evidence that this category is feasible. Our window-title reader does not
implement those participant/speaker observations.

Design implication: live UI speaker observations must be timestamped during
recording if they are to be used after the call closes. A post-session agent
cannot reconstruct missing UI events from the WAV. Matching diarization to the
current phrase-level JSONL may also require finer alignment when a phrase spans
two speakers; the current transcript does not supply word-level timing.

No local or remote diarization provider is bundled. Configure analysis and
derived speaker/name outputs through explicit hooks, retaining uncertainty when
evidence is absent.
