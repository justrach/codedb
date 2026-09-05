# ADR 0011: Guard intent before release 0.2.5853

Status: release hardening after automated review of PR 743.

Review identified two correctness gaps in ADR 0010's heuristic. A whole-word
mention of test is not necessarily a request for tests: production test runners
and test discovery must not have production results demoted. Likewise, ordinary
calls/use/used/invoked requests must not hard-pin a definition ahead of reference
sites.

Require a test-seeking verb and a test noun phrase. Allow polite request
prefixes, and keep test-runner/discovery/infrastructure descriptions outside the
test-finding intent. A request for tests of the test runner still seeks tests.
Dependency intent recognizes whole-word call, use, reference, invocation and
consumer forms before permitting exact-definition priority. Identifier substrings
such as useGatewayAuth remain eligible for explicit definition lookup.

Targeted unit cases cover both review examples, polite test requests, tests of
a test runner, ordinary dependency inflections, and identifier substrings.
These are conservative lexical intent guards, not a general natural-language
parser. Hosted Jina, ranking constants, ANN breadth and fallback are unchanged.

This patch follows the previous candidate freeze. All 128 existing questions are
now regression data: rerun them against the frozen ADR 0010 binary before release,
without calling this a new holdout. Release checks also require the full Zig
suite, MCP end-to-end scenarios and GitHub benchmark gates. Final validation and
publication state are recorded in [PR 743](https://github.com/justrach/codedb/pull/743)
and the 0.2.5853 release. Rebuild and notarize artifacts from the corrected commit;
do not ship binaries produced before these fixes.
