#!/usr/bin/env python3
"""Case builders for the four-arm Graff prompt tournament."""

from __future__ import annotations

import json
import secrets
from typing import Any


def _case(
    case_id: str,
    task: str,
    check: dict[str, str],
    setup: dict[str, str] | None = None,
    *,
    critical: bool = False,
    statistical_unit_id: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {"id": case_id, "task": task, "check": check}
    if setup is not None:
        payload["setup_files"] = setup
    result: dict[str, Any] = {"id": case_id, "payload": payload}
    if critical:
        result["critical"] = True
    if statistical_unit_id is not None:
        result["statistical_unit_id"] = statistical_unit_id
    return result


def _exact(case_id: str, task: str, expected: str, setup: dict[str, str] | None = None) -> dict[str, Any]:
    return _case(case_id, task, {"exact": expected}, setup)


def _mutation(case_id: str, task: str, command: str, setup: dict[str, str] | None = None,
              *, statistical_unit_id: str | None = None) -> dict[str, Any]:
    return _case(case_id, task, {"cmd": command}, setup, critical=True,
                 statistical_unit_id=statistical_unit_id)


def primary_cases() -> list[dict[str, Any]]:
    """Sixty randomized public cases, including twenty edit-economy probes."""
    sort_values = [secrets.randbelow(80) + 1 for _ in range(3)]
    while len(set(sort_values)) != 3:
        sort_values = [secrets.randbelow(80) + 1 for _ in range(3)]
    nested_maximum = secrets.randbelow(70) + 20
    selected_price = secrets.randbelow(70) + 20
    desired_threshold = secrets.randbelow(70) + 20
    factor_a, factor_b = secrets.randbelow(30) + 11, secrets.randbelow(30) + 11
    ledger_values = [secrets.randbelow(50) + 10 for _ in range(4)]
    sum_values = [secrets.randbelow(40) + 5 for _ in range(4)]
    cases = [
        # Semantic boundaries and exactness.
        _exact(
            "semantic-count-unterminated",
            "Count the lines of text in notes.txt and reply with only the number.",
            "3",
            {"notes.txt": "alpha\nbravo\ncharlie"},
        ),
        _exact(
            "semantic-count-empty",
            "Count the lines of text in empty.txt and reply with only the number.",
            "0",
            {"empty.txt": ""},
        ),
        _exact(
            "semantic-count-blank-record",
            "Count all text lines in stanza.txt, including blank lines, and reply with only the number.",
            "3",
            {"stanza.txt": "alpha\n\ncharlie\n"},
        ),
        _mutation(
            "semantic-exact-no-newline",
            "Create status.txt containing exactly the five characters READY with no trailing newline.",
            "test \"$(cat status.txt)\" = READY && test \"$(wc -c < status.txt)\" -eq 5",
        ),
        _mutation(
            "semantic-preserve-unterminated",
            "In phrase.txt replace beta with BETA while preserving every other byte, including the lack of a trailing newline.",
            "test \"$(cat phrase.txt)\" = 'alpha\nBETA' && test \"$(wc -c < phrase.txt)\" -eq 10",
            {"phrase.txt": "alpha\nbeta"},
        ),
        _mutation(
            "semantic-numeric-sort",
            "Sort the integers in unsorted.txt numerically into sorted.txt, one per line.",
            "test \"$(cat sorted.txt)\" = '" + "\n".join(map(str, sorted(sort_values))) + "'",
            {"unsorted.txt": "\n".join(map(str, reversed(sort_values))) + "\n"},
        ),
        _exact(
            "semantic-csv-header",
            "Reply with only the sum of the amount column in sales.csv, excluding the header.",
            "60",
            {"sales.csv": "item,amount\na,10\nb,20\nc,30\n"},
        ),
        _exact(
            "semantic-count-crlf",
            "Count the text lines in windows.txt and reply with only the number.",
            "2",
            {"windows.txt": "red\r\nblue\r\n"},
        ),
        _mutation(
            "semantic-preserve-terminal-newline",
            "In word.txt uppercase only gamma while preserving its trailing newline.",
            "test \"$(cat word.txt)\" = 'alpha GAMMA' && test \"$(wc -c < word.txt)\" -eq 12",
            {"word.txt": "alpha gamma\n"},
        ),
        _exact(
            "semantic-nested-number",
            "Read limits.json and reply with only the integer at worker.maximum.",
            str(nested_maximum),
            {"limits.json": json.dumps({"worker": {"minimum": 3, "maximum": nested_maximum}}) + "\n"},
        ),

        # Exact edit transactions and state preservation.
        _mutation(
            "edit-replace-all",
            "In greeting.txt change every standalone world to graff, preserving all other text.",
            "test \"$(cat greeting.txt)\" = 'hello graff\ngoodbye graff\nkeep'",
            {"greeting.txt": "hello world\ngoodbye world\nkeep\n"},
        ),
        _mutation(
            "edit-replace-first-only",
            "In queue.txt change only the first occurrence of pending to ready, leaving the later occurrence unchanged.",
            "test \"$(sed -n 1p queue.txt)\" = ready && test \"$(sed -n 2p queue.txt)\" = pending && test \"$(sed -n 3p queue.txt)\" = keep",
            {"queue.txt": "pending\npending\nkeep\n"},
        ),
        _mutation(
            "edit-append-preserve",
            "Append the line gamma to log.txt, keeping all existing lines unchanged.",
            "test \"$(cat log.txt)\" = 'alpha\nbeta\ngamma'",
            {"log.txt": "alpha\nbeta\n"},
        ),
        _mutation(
            "edit-delete-stable",
            "Remove every line containing DROP from data.txt without reordering the remaining lines.",
            "test \"$(cat data.txt)\" = 'keep1\nkeep2\nkeep3'",
            {"data.txt": "keep1\nDROP me\nkeep2\nDROP again\nkeep3\n"},
        ),
        _mutation(
            "edit-dedupe-stable",
            "Remove duplicate lines from colors.txt in place, keeping first-occurrence order.",
            "test \"$(cat colors.txt)\" = 'red\nblue\ngreen'",
            {"colors.txt": "red\nblue\nred\ngreen\nblue\n"},
        ),
        _mutation(
            "edit-target-exact-key",
            "In app.env change only the exact line mode=dev to mode=prod; do not change mode_backup.",
            "test \"$(sed -n 1p app.env)\" = mode=prod && test \"$(sed -n 2p app.env)\" = mode_backup=dev",
            {"app.env": "mode=dev\nmode_backup=dev\n"},
        ),
        _mutation(
            "edit-already-satisfied",
            "Ensure flags.conf contains exactly enabled=true. If it already does, leave it unchanged.",
            "test \"$(cat flags.conf)\" = enabled=true && test \"$(wc -c < flags.conf)\" -eq 13",
            {"flags.conf": "enabled=true\n"},
        ),
        _mutation(
            "edit-remove-comments",
            "Remove lines beginning with # from settings.ini without changing other lines.",
            "test \"$(cat settings.ini)\" = 'mode=fast\nlevel=2'",
            {"settings.ini": "# generated\nmode=fast\n# keep out\nlevel=2\n"},
        ),
        _mutation(
            "edit-collapse-adjacent-duplicates",
            "Collapse adjacent duplicate lines in sequence.txt, preserving first-occurrence order.",
            "test \"$(cat sequence.txt)\" = 'a\nb\na\nc'",
            {"sequence.txt": "a\na\nb\nb\na\nc\nc\n"},
        ),
        _mutation(
            "edit-noop-exact",
            "Ensure policy.txt contains exactly allow=yes. It already does, so do not rewrite it.",
            "test \"$(cat policy.txt)\" = allow=yes && test \"$(wc -c < policy.txt)\" -eq 10",
            {"policy.txt": "allow=yes\n"},
        ),

        # Independent evidence and dependency ordering.
        _exact(
            "dependency-compare-json",
            "Read east.json and west.json and reply with only the region whose latency value is lower.",
            "east",
            {"east.json": '{"latency":17}\n', "west.json": '{"latency":29}\n'},
        ),
        _exact(
            "dependency-sum-two-files",
            "Reply with only the sum of all integers across left.txt and right.txt.",
            "42",
            {"left.txt": "4\n8\n", "right.txt": "10\n20\n"},
        ),
        _mutation(
            "dependency-merge-unique",
            "Combine a.txt and b.txt into merged.txt, sorted alphabetically with duplicate lines removed.",
            "test \"$(cat merged.txt)\" = 'apple\nbanana\ncherry\ndate'",
            {"a.txt": "banana\napple\ncherry\n", "b.txt": "cherry\ndate\napple\n"},
        ),
        _exact(
            "dependency-keyed-lookup",
            "Use current.txt to choose the matching key in values.txt, then reply with only its numeric value.",
            "73",
            {"current.txt": "blue\n", "values.txt": "red 41\nblue 73\ngreen 19\n"},
        ),
        _mutation(
            "dependency-sync-config",
            "Read desired.json and update only the port value in service.json to match it.",
            "grep -q '\"host\":\"local\"' service.json && grep -Eq '\"port\"[[:space:]]*:[[:space:]]*4117' service.json",
            {"desired.json": '{"port":4117}\n', "service.json": '{"host":"local","port":3000}\n'},
        ),
        _mutation(
            "dependency-set-intersection",
            "Write common.txt with the values present in both first.txt and second.txt, sorted, one per line.",
            "test \"$(cat common.txt)\" = 'blue\ngreen'",
            {"first.txt": "red\nblue\ngreen\n", "second.txt": "green\nblue\ngold\n"},
        ),
        _exact(
            "dependency-max-three-files",
            "Read one.txt, two.txt, and three.txt and reply with only the largest integer found.",
            "91",
            {"one.txt": "17\n", "two.txt": "91\n", "three.txt": "44\n"},
        ),
        _exact(
            "dependency-selected-price",
            "Use selected.txt to choose the matching item in prices.txt and reply with only its price.",
            str(selected_price),
            {"selected.txt": "pear\n", "prices.txt": f"apple 31\npear {selected_price}\nplum 52\n"},
        ),
        _mutation(
            "dependency-combine-columns",
            "Pair each line of names.txt with the same-position line of scores.txt in result.txt as name=score.",
            "test \"$(cat result.txt)\" = 'ada=8\nlin=13\nmax=21'",
            {"names.txt": "ada\nlin\nmax\n", "scores.txt": "8\n13\n21\n"},
        ),
        _mutation(
            "dependency-copy-threshold",
            "Read desired.conf and update only threshold in runtime.conf to match it.",
            f"grep -q '^name=worker$' runtime.conf && grep -q '^threshold={desired_threshold}$' runtime.conf",
            {"desired.conf": f"threshold={desired_threshold}\n", "runtime.conf": "name=worker\nthreshold=40\n"},
        ),

        # Outcome stopping and minimum sufficient evidence.
        _exact("economy-arithmetic", f"Compute {factor_a}*{factor_b} and reply with only the number.", str(factor_a * factor_b)),
        _exact(
            "economy-single-extract",
            "Read cfg.json and reply with only the value of service.port.",
            "4117",
            {"cfg.json": '{"service":{"port":4117},"debug":false}\n'},
        ),
        _mutation(
            "economy-simple-create",
            "Create out.txt whose entire content is exactly hello-dgm with no trailing newline.",
            "test \"$(cat out.txt)\" = hello-dgm && test \"$(wc -c < out.txt)\" -eq 9",
        ),
        _mutation(
            "economy-zero-byte",
            "Create blank.bin containing exactly zero bytes.",
            "test -f blank.bin && test ! -s blank.bin",
        ),
        _mutation(
            "economy-simple-edit",
            "In title.txt replace draft with final, leaving everything else unchanged.",
            "test \"$(cat title.txt)\" = 'status: final'",
            {"title.txt": "status: draft\n"},
        ),
        _mutation(
            "economy-ledger-write",
            "Sum the numeric second column of ledger.txt and write only the total to total.txt.",
            f"test \"$(cat total.txt)\" = {sum(ledger_values)}",
            {"ledger.txt": "\n".join(f"item{index} {value}" for index, value in enumerate(ledger_values)) + "\n"},
        ),
        _exact(
            "economy-already-done",
            "Read state.txt. If it says complete, reply with only done.",
            "done",
            {"state.txt": "complete\n"},
        ),
        _mutation(
            "economy-sum-write",
            "Sum the integers in values.txt and write only the total to sum.txt.",
            f"test \"$(cat sum.txt)\" = {sum(sum_values)}",
            {"values.txt": "\n".join(map(str, sum_values)) + "\n"},
        ),
        _mutation(
            "economy-uppercase-write",
            "Read label.txt and write its uppercase text to upper.txt with no trailing newline.",
            "test \"$(cat upper.txt)\" = ORBIT && test \"$(wc -c < upper.txt)\" -eq 5",
            {"label.txt": "orbit\n"},
        ),
        _mutation(
            "economy-filter-write",
            "Write clean.txt from raw.txt with lines beginning TEMP: removed, preserving all others.",
            "test \"$(cat clean.txt)\" = 'first\nsecond\nthird'",
            {"raw.txt": "first\nTEMP:x\nsecond\nTEMP:y\nthird\n"},
        ),
    ]
    for index in range(5):
        token = secrets.token_hex(3)
        name = f"ready{index}.conf"
        cases.append(_mutation(
            f"edit-noop-random-{index}",
            f"Ensure {name} contains exactly state={token}. It already does, so leave it unchanged.",
            f"test \"$(cat {name})\" = state={token} && test \"$(wc -c < {name})\" -eq {len(token) + 7}",
            {name: f"state={token}\n"},
            statistical_unit_id="edit-noop",
        ))
    for index in range(5):
        cases.append(_mutation(
            f"edit-filter-random-{index}",
            f"Remove lines beginning DROP: from filter{index}.txt without reordering the other lines.",
            f"test \"$(cat filter{index}.txt)\" = 'a{index}\nb{index}\nc{index}'",
            {f"filter{index}.txt": f"a{index}\nDROP:x\nb{index}\nDROP:y\nc{index}\n"},
            statistical_unit_id="edit-filter",
        ))
    for index in range(5):
        cases.append(_mutation(
            f"edit-dedupe-random-{index}",
            f"Deduplicate ids{index}.txt in place, preserving first-occurrence order.",
            f"test \"$(cat ids{index}.txt)\" = 'k{index}a\nk{index}b\nk{index}c'",
            {f"ids{index}.txt": f"k{index}a\nk{index}b\nk{index}a\nk{index}c\nk{index}b\n"},
            statistical_unit_id="edit-dedupe",
        ))
    for index in range(5):
        desired_value = secrets.randbelow(8000) + 1000
        cases.append(_mutation(
            f"edit-copy-random-{index}",
            f"Read desired{index}.ini and update only limit in runtime{index}.ini to match it.",
            f"grep -q '^name=worker{index}$' runtime{index}.ini && grep -q '^limit={desired_value}$' runtime{index}.ini",
            {
                f"desired{index}.ini": f"limit={desired_value}\n",
                f"runtime{index}.ini": f"name=worker{index}\nlimit=10\n",
            },
            statistical_unit_id="edit-copy",
        ))
    return cases


def fresh_holdout() -> list[dict[str, Any]]:
    """Forty randomized, structurally shifted cases kept away from mutation."""
    token = secrets.token_hex(5)
    product_a, product_b = secrets.randbelow(30) + 11, secrets.randbelow(30) + 11
    port = secrets.randbelow(7000) + 2000
    numbers = [secrets.randbelow(40) + 10 for _ in range(4)]
    desired = secrets.randbelow(7000) + 2000
    cases = [
        _exact("fresh-sem-crlf-records", "Count the text lines in routes.txt and reply with only the number.", "3", {"routes.txt": "north\r\nsouth\r\neast"}),
        _exact("fresh-sem-blank-record", "Count all lines in verse.txt, including blank lines, and reply with only the number.", "3", {"verse.txt": "one\n\nthree"}),
        _mutation("fresh-sem-exact-token", f"Create token.dat containing exactly {token} with no trailing newline.", f"test \"$(cat token.dat)\" = {token} && test \"$(wc -c < token.dat)\" -eq {len(token)}"),
        _mutation("fresh-sem-preserve-newline", "In pair.txt replace right with RIGHT while preserving its trailing newline.", "test \"$(cat pair.txt)\" = 'left\nRIGHT' && test \"$(wc -c < pair.txt)\" -eq 11", {"pair.txt": "left\nright\n"}),
        _exact("fresh-sem-tsv-header", "Reply with only the sum of the amount column in report.tsv, excluding its header.", "45", {"report.tsv": "name\tamount\na\t12\nb\t14\nc\t19\n"}),
        _mutation("fresh-sem-preserve-terminal", "In tail.txt uppercase only end while preserving its trailing newline.", "test \"$(cat tail.txt)\" = 'start\nEND' && test \"$(wc -c < tail.txt)\" -eq 10", {"tail.txt": "start\nend\n"}),
        _exact("fresh-sem-nested-value", "Read quota.json and reply with only pool.available.", "29", {"quota.json": '{"pool":{"used":11,"available":29}}\n'}),

        _mutation("fresh-edit-last-only", "In stages.txt change only the last pending line to ready.", "test \"$(sed -n 1p stages.txt)\" = pending && test \"$(sed -n 2p stages.txt)\" = pending && test \"$(sed -n 3p stages.txt)\" = ready", {"stages.txt": "pending\npending\npending\n"}),
        _mutation("fresh-edit-append-unterminated", "Append the line dusk to day.txt while preserving its existing two lines.", "test \"$(cat day.txt)\" = 'dawn\nnoon\ndusk'", {"day.txt": "dawn\nnoon"}),
        _mutation("fresh-edit-delete-prefix", "Remove lines beginning with OMIT: from items.txt without reordering other lines.", "test \"$(cat items.txt)\" = 'first\nsecond\nthird'", {"items.txt": "first\nOMIT:x\nsecond\nOMIT:y\nthird\n"}),
        _mutation("fresh-edit-dedupe-ids", "Deduplicate ids.txt in place, retaining first-occurrence order.", "test \"$(cat ids.txt)\" = 'k2\nk1\nk3'", {"ids.txt": "k2\nk1\nk2\nk3\nk1\n"}),
        _mutation("fresh-edit-noop", "Ensure switch.ini contains exactly active=yes. If it already does, leave it unchanged.", "test \"$(cat switch.ini)\" = active=yes && test \"$(wc -c < switch.ini)\" -eq 11", {"switch.ini": "active=yes\n"}),
        _mutation("fresh-edit-remove-marked", "Remove lines beginning SKIP: from rows.txt without reordering the remaining lines.", "test \"$(cat rows.txt)\" = 'north\nsouth\neast'", {"rows.txt": "north\nSKIP:x\nsouth\nSKIP:y\neast\n"}),
        _mutation("fresh-edit-adjacent-dedupe", "Collapse adjacent duplicate lines in runs.txt while preserving order.", "test \"$(cat runs.txt)\" = 'x\ny\nx\nz'", {"runs.txt": "x\nx\ny\ny\nx\nz\nz\n"}),

        _exact("fresh-dep-compare-ini", "Read alpha.ini and beta.ini and reply with only the name having the larger score.", "beta", {"alpha.ini": "score=31\n", "beta.ini": "score=48\n"}),
        _exact("fresh-dep-chain-lookup", "Use selected.txt to choose a row in catalog.txt and reply with only that row's code.", "ZX7", {"selected.txt": "moon\n", "catalog.txt": "sun AB2\nmoon ZX7\nstar LM4\n"}),
        _mutation("fresh-dep-join-labels", "Use labels.txt to replace each numeric key in keys.txt and write the labels to result.txt in key order.", "test \"$(cat result.txt)\" = 'oak\npine\ncedar'", {"keys.txt": "2\n1\n3\n", "labels.txt": "1 pine\n2 oak\n3 cedar\n"}),
        _mutation("fresh-dep-union", "Write union.txt containing the unique values from north.txt and south.txt, sorted alphabetically.", "test \"$(cat union.txt)\" = 'amber\ncyan\nindigo\nviolet'", {"north.txt": "violet\namber\ncyan\n", "south.txt": "cyan\nindigo\namber\n"}),
        _mutation("fresh-dep-transfer-value", "Read desired.ini and update only timeout in runtime.ini to match it.", f"grep -q '^name=gateway$' runtime.ini && grep -q '^timeout={desired}$' runtime.ini", {"desired.ini": f"timeout={desired}\n", "runtime.ini": "name=gateway\ntimeout=30\n"}),
        _exact("fresh-dep-selected-code", "Use wanted.txt to choose the matching row in codes.txt and reply with only its code.", "Q9", {"wanted.txt": "cedar\n", "codes.txt": "oak A2\ncedar Q9\npine M4\n"}),
        _mutation("fresh-dep-zipped-pairs", "Pair same-position lines from keys.txt and vals.txt into paired.txt as key:value.", "test \"$(cat paired.txt)\" = 'a:3\nb:5\nc:8'", {"keys.txt": "a\nb\nc\n", "vals.txt": "3\n5\n8\n"}),

        _exact("fresh-econ-product", f"Compute {product_a}*{product_b} and reply with only the number.", str(product_a * product_b)),
        _exact("fresh-econ-json", "Read runtime.json and reply with only runtime.port.", str(port), {"runtime.json": json.dumps({"runtime": {"port": port}}) + "\n"}),
        _mutation("fresh-econ-create", "Create signal.txt containing exactly GO with no trailing newline.", "test \"$(cat signal.txt)\" = GO && test \"$(wc -c < signal.txt)\" -eq 2"),
        _mutation("fresh-econ-empty", "Create void.dat as an exactly zero-byte file.", "test -f void.dat && test ! -s void.dat"),
        _mutation("fresh-econ-sum-write", "Sum the integers in amounts.txt and write only the total to answer.txt.", f"test \"$(cat answer.txt)\" = {sum(numbers)}", {"amounts.txt": "\n".join(map(str, numbers)) + "\n"}),
        _mutation("fresh-econ-uppercase", "Read phase.txt and write its uppercase text to loud.txt with no trailing newline.", "test \"$(cat loud.txt)\" = AURORA && test \"$(wc -c < loud.txt)\" -eq 6", {"phase.txt": "aurora\n"}),
        _mutation("fresh-econ-filter", "Write kept.txt from source.txt with lines beginning DROP: removed, preserving all others.", "test \"$(cat kept.txt)\" = 'one\ntwo\nthree'", {"source.txt": "one\nDROP:a\ntwo\nDROP:b\nthree\n"}),
        _mutation("fresh-shift-reverse-block", "Reverse the line order in queue.txt in place.", "test \"$(cat queue.txt)\" = 'third\nsecond\nfirst'", {"queue.txt": "first\nsecond\nthird\n"}),
        _mutation("fresh-shift-rename-key", "In theme.ini rename only the key colour to color without changing its value or any other line.", "test \"$(cat theme.ini)\" = 'name=night\ncolor=blue\nmode=calm'", {"theme.ini": "name=night\ncolour=blue\nmode=calm\n"}),
        _mutation("fresh-shift-interleave", "Interleave same-position lines from left.txt and right.txt into woven.txt, starting with left.", "test \"$(cat woven.txt)\" = 'L1\nR1\nL2\nR2\nL3\nR3'", {"left.txt": "L1\nL2\nL3\n", "right.txt": "R1\nR2\nR3\n"}),
        _mutation("fresh-shift-last-occurrence", "In flags.txt change only the final old line to new.", "test \"$(cat flags.txt)\" = 'old\nkeep\nold\nnew'", {"flags.txt": "old\nkeep\nold\nold\n"}),
        _mutation("fresh-shift-extract-column", "Write ranks.txt containing the numeric second column of table.txt sorted ascending, one value per line.", "test \"$(cat ranks.txt)\" = '2\n7\n11'", {"table.txt": "oak 11\npine 2\ncedar 7\n"}),
        _mutation("fresh-shift-section-update", "In service.ini change timeout to 45 only inside the worker section.", "test \"$(cat service.ini)\" = '[global]\ntimeout=10\n[worker]\ntimeout=45\nretries=2'", {"service.ini": "[global]\ntimeout=10\n[worker]\ntimeout=30\nretries=2\n"}),
        _mutation("fresh-shift-prefix-nonblank", "Prefix every nonblank line in notes.txt with '- ' while preserving the blank line.", "test \"$(cat notes.txt)\" = '- alpha\n\n- beta'", {"notes.txt": "alpha\n\nbeta\n"}),
        _mutation("fresh-shift-json-labels", "Read the objects in items.json and write their label values to labels.txt in array order.", "test \"$(cat labels.txt)\" = 'ember\nfrost\ngrove'", {"items.json": '[{"label":"ember"},{"label":"frost"},{"label":"grove"}]\n'}),
    ]
    for index in range(1):
        fresh_token = secrets.token_hex(4)
        name = f"fresh-ready{index}.cfg"
        cases.append(_mutation(
            f"fresh-edit-noop-random-{index}",
            f"Ensure {name} contains exactly ready={fresh_token}. It already does; leave it unchanged.",
            f"test \"$(cat {name})\" = ready={fresh_token} && test \"$(wc -c < {name})\" -eq {len(fresh_token) + 7}",
            {name: f"ready={fresh_token}\n"},
        ))
    for index in range(1):
        cases.append(_mutation(
            f"fresh-edit-filter-random-{index}",
            f"Remove lines beginning OMIT: from fresh-filter{index}.txt without reordering other lines.",
            f"test \"$(cat fresh-filter{index}.txt)\" = 'p{index}\nq{index}\nr{index}'",
            {f"fresh-filter{index}.txt": f"p{index}\nOMIT:x\nq{index}\nOMIT:y\nr{index}\n"},
        ))
    for index in range(1):
        cases.append(_mutation(
            f"fresh-edit-dedupe-random-{index}",
            f"Deduplicate fresh-ids{index}.txt in place while preserving first-occurrence order.",
            f"test \"$(cat fresh-ids{index}.txt)\" = 'v{index}a\nv{index}b\nv{index}c'",
            {f"fresh-ids{index}.txt": f"v{index}a\nv{index}b\nv{index}a\nv{index}c\nv{index}b\n"},
        ))
    for index in range(1):
        desired_limit = secrets.randbelow(8000) + 1000
        cases.append(_mutation(
            f"fresh-edit-copy-random-{index}",
            f"Read wanted{index}.conf and update only limit in live{index}.conf to match it.",
            f"grep -q '^name=service{index}$' live{index}.conf && grep -q '^limit={desired_limit}$' live{index}.conf",
            {
                f"wanted{index}.conf": f"limit={desired_limit}\n",
                f"live{index}.conf": f"name=service{index}\nlimit=20\n",
            },
        ))
    return cases


def validate_case_catalog(cases: list[dict[str, Any]], expected: int) -> None:
    if len(cases) != expected or len({case.get("id") for case in cases}) != expected:
        raise ValueError(f"expected {expected} unique cases")
    for case in cases:
        payload = case.get("payload")
        if not isinstance(payload, dict) or not isinstance(payload.get("task"), str):
            raise ValueError("every case needs a task payload")
        check = payload.get("check")
        if not isinstance(check, dict) or len(check) != 1:
            raise ValueError("every case needs exactly one check")
    criticality: dict[str, bool] = {}
    for case in cases:
        unit = case.get("statistical_unit_id", case["id"])
        critical = bool(case.get("critical", False))
        if unit in criticality and criticality[unit] != critical:
            raise ValueError("one statistical unit cannot mix criticality")
        criticality[unit] = critical


def statistical_unit_count(cases: list[dict[str, Any]]) -> int:
    return len({case.get("statistical_unit_id", case["id"]) for case in cases})


if __name__ == "__main__":
    primary, holdout = primary_cases(), fresh_holdout()
    validate_case_catalog(primary, 60)
    validate_case_catalog(holdout, 40)
    print(json.dumps({
        "primary": len(primary), "primary_units": statistical_unit_count(primary),
        "holdout": len(holdout), "holdout_units": statistical_unit_count(holdout),
    }))
