#!/bin/sh
# オートメーション(ios/PovoX/Flows の Foundation だけの部分)を、iOS なしでコンパイルして検査する。
# Swift があれば Linux でも動く: sh tools/flow-check.sh
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/povox-flow-check"
swiftc -O -o "$out" \
  ios/PovoX/Flows/FlowModel.swift ios/PovoX/Flows/DayPlanner.swift ios/PovoX/Flows/FlowEngine.swift \
  ios/PovoX/Flows/FlowText.swift ios/PovoX/Flows/FlowGallery.swift ios/PovoX/Diagnostics/WakeLog.swift \
  ios/PovoX/Flows/JapaneseHolidays.swift ios/PovoX/Flows/UsageLearner.swift \
  ios/PovoXTests/Flows/FlowLogicChecks.swift ios/PovoXTests/Flows/WakeChecks.swift ios/PovoXTests/Flows/LearnChecks.swift tools/flow-check/main.swift
"$out"
