# STT accuracy benchmark dataset

`starter_manifest.json` defines an initial controlled set of 24 utterances.
It is designed to expose accuracy differences across ordinary Vietnamese,
short and long speech, numbers, proper names, technical vocabulary,
Vietnamese-English mixing, and a few English phrases. It is not representative
of all Vietnamese speakers, accents, environments, or speaking styles.

## Recording contract

Record each case exactly as written and store it at the manifest-relative path:

```text
recordings/<case_id>.wav
```

The `recordings/` directory is excluded from source control by the repository's
existing ignore rules. No recordings are included in this checkpoint.

Every recording must be an uncompressed WAV containing signed PCM samples:

- one channel (mono)
- 16000 Hz sample rate
- 16-bit sample width
- little-endian sample encoding

The runner rejects mismatched files. It does not resample, remix, or invoke
FFmpeg.

## Run

Run from `services/api` after configuring the existing application environment
with `STT_PROVIDER=deepgram` and `DEEPGRAM_API_KEY`. The API key is never passed
as a CLI argument.

```powershell
python -m scripts.stt_accuracy_benchmark `
  --manifest benchmarks/stt_accuracy/starter_manifest.json `
  --output-dir tmp/stt-accuracy-results
```

Use repeatable `--category <name>` or `--case-id <id>` filters to select a
subset. Running the command sends recorded audio to the paid provider; review
the selected cases before execution.

The runner uses the application's existing Deepgram adapter and current fixed
configuration (`nova-3`, language `vi`, endpointing 300 ms). Audio is paced in
100 ms chunks. Non-empty finalized segments are concatenated in provider order;
interim revisions are used only to capture first-interim latency.

## Scoring and failures

Scoring normalization applies Unicode NFC, lowercases text, replaces every
Unicode punctuation code point with a space, and collapses whitespace. It does
not translate, correct vocabulary, remove Vietnamese diacritics, or remove
English tokens. CER counts Unicode code points, including the normalized single
spaces between words.

WER and CER use Levenshtein substitutions, deletions, and insertions. Each rate
is `errors / max(1, reference_count)`, which gives empty/empty a rate of zero and
keeps non-empty hypotheses against an empty reference explicit. Failed cases
are counted as failures and excluded from accuracy and latency aggregates.

The JSON report contains nested edit counts, raw and normalized text, provider
metadata, latencies, errors, and overall/category summaries. The CSV report has
one case per row and flattens word and character edit counts into columns.
Neither report contains credentials, headers, or raw audio bytes.
