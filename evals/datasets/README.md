# Accuracy dataset inventory

The round-3 suite contains 128 positive file-retrieval questions across six
repositories. Each dataset pins its source revision and every corpus file hash.
Questions are hand-authored and source-checked; targets are correlated and do
not establish broad language coverage, answer accuracy, or abstention quality.

| Repository | Questions | Files | Role during round 3 |
| --- | ---: | ---: | --- |
| [openclaw](openclaw-autoresearch-v2.json) | 32 | 34 | development |
| [express](express-jina-accuracy-heldout-v1.json) | 16 | 35 | development |
| [flask](flask-jina-accuracy-heldout-v1.json) | 20 | 46 | development |
| [chi](chi-jina-round3-v2.json) | 20 | 65 | development |
| [anyhow](anyhow-jina-round3-v1.json) | 20 | 26 | development |
| [requests](requests-jina-round3-v1.json) | 20 | 28 | holdout |

Chi covers root and middleware Go files, including their tests. Anyhow covers
its Rust src and top-level test files. Requests covers its Python package and
top-level test modules. Full repositories are not indexed by these fixtures.

The Requests split was untouched until the candidate freeze for round 3. Its
results have now been collected, so it is observed regression data too. An historical
held_out field never makes repeated tuning against those questions valid.

## Label audit

Chi v1 question chi-03 described extracting an address from forwarded headers.
Both middleware/realip.go and middleware/client_ip.go satisfy that wording.
Before policy tuning, v2 added the second legitimate target with equal grade.
The original dataset and its baseline report remain intact; all policy
comparisons use v2 on both arms. Relevance improvements from this annotation
correction are not counted as code improvements. The source corpus is identical
between versions, so the same hosted-Jina sidecar is reused.

The initial baselines for new datasets were collected using the ADR 0009 binary
on both arms, checking service behavior before any candidate. They are not
independent samples from different ranking policies.
