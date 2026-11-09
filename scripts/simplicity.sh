#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
# How much does it cost to integrate meta-laavat into one BSP?
#
# The answer has to stay small, or the layer is not the product it claims to be. This
# measures every sample-* layer and fails if one grows past the budget or starts carrying
# python. A sample layer holds bbappends, a bundle recipe and a layer.conf - nothing else.
#
# Budget is per layer, in non-comment non-blank lines across .bb/.bbappend/.inc/layer.conf.
# It is deliberately tight: the three newest tiers land near 29.
BUDGET=${BUDGET:-70}
status=0

printf '%-26s %6s %7s %8s\n' LAYER LINES PYTHON VERDICT
for d in sample-*/; do
    [ -d "$d" ] || continue
    name=${d%/}
    files=$(find "$d" \( -name '*.bb' -o -name '*.bbappend' -o -name '*.inc' \
                       -o -name 'layer.conf' \) 2>/dev/null)
    lines=$(cat $files 2>/dev/null | grep -vcE '^[[:space:]]*(#|$)')
    py=$(find "$d" -name '*.py' 2>/dev/null | wc -l)
    verdict=ok
    if [ "$py" -ne 0 ]; then
        verdict="FAIL: python in a sample layer"
        status=1
    elif [ "$lines" -gt "$BUDGET" ]; then
        verdict="FAIL: over budget $BUDGET"
        status=1
    fi
    printf '%-26s %6s %7s %8s\n' "$name" "$lines" "$py" "$verdict"
done

if [ "$status" -ne 0 ]; then
    echo
    echo "A sample layer is integration and nothing else: guarded inherits, the board facts"
    echo "the class cannot know, and a bundle recipe. Anything that needs python belongs in"
    echo "signing-tool as a verb - meta-laavat carries none either - and anything that is"
    echo "test scaffolding belongs in testbed-fixtures/."
fi
exit $status
