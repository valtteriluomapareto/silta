# Native pilot replay evidence

`400k/` contains the four recorded Codex trials from the first open-model pilot;
`cap50k/` contains the start-cross-repo trial that exposed lost forbidden-attempt
violations on infrastructure failure. Each directory retains native phase streams,
the command log and the evidence snapshots needed for offline grading. No model
or provider is contacted by these replays.

Copies normalize the temporary trial roots to `/tmp/acme-eval`, user paths to
`/Users/acme`, the public model account path to `acme-pilot-model`, and UUIDs to
stable hashed Acme identifiers. The stray quote in handoff-resume's malformed
path remains, as do cap-stopped streams and actual command/log ordering. Transcript
hashes are historical source hashes, not certifications of the normalized bytes;
tests reparse the streams and do not apply the original review digest.

The successful done-with-result turn passes stream completeness. The successful
start-cross-repo turn has interleaved command completions and logs that fail ordered
matching. Plan-not-file and handoff-resume hit their token caps and retain those
infrastructure failures. Opaque shell calls require explicit bound shell-trace
review; no fixture invents that review or erases a native failure.
