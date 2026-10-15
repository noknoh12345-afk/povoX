#!/usr/bin/env python3
"""povoX のレシピ(ルールの組み合わせプリセット)の一覧を作る。

レシピは「パラメータ」だけを持ち、実際のルール(JavaScript)はアプリ側の
RecipeCompiler がパラメータから組み立てる。ここでは重複のない組み合わせを
日本語の名前つきで列挙して recipes.json に書き出す。安全装置(上限・回数・
間隔・3DS 除外)はエンジン側が必ずかけるので、レシピは「何をするか」だけ。
"""
import json, itertools, sys

# しきい値: 残量(GB)と「あと何時間」
GB = [0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 3.0]
HOURS = [1, 2, 3, 6, 12]

def gbname(g):
    return (f"{int(g*1000)}MB" if g < 1 else f"{g:g}GB")

# やること(順に試す=firstOf)。id と、人に見せる短い名前。
ACTIONS = {
    "code":        "手持ちのコード",
    "dataCheap":   "データ追加(1GBあたり最安)",
    "unl1":        "1時間の使い放題",
    "unl24":       "24時間の使い放題",
    "unlSmart":    "使い放題(電池が少なければ1時間)",
    "notify":      "知らせるだけ",
}

recipes = []
seen = set()

def add(cat, title, summary, params):
    key = json.dumps(params, sort_keys=True)
    if key in seen:
        return
    seen.add(key)
    rid = "r%03d" % (len(recipes) + 1)
    recipes.append({"id": rid, "category": cat, "title": title, "summary": summary, "params": params})

# ---- 1. 残量ラインで動く(しきい値 × やること) -------------------------------
LINE_ACTS = [
    (["code", "unlSmart", "notify"], "コード→使い放題"),
    (["code", "dataCheap", "notify"], "コード→データ追加"),
    (["code", "notify"], "コードだけ"),
    (["unl24", "notify"], "24時間使い放題"),
    (["unl1", "notify"], "1時間使い放題"),
    (["dataCheap", "notify"], "データ追加"),
    (["code", "unl1", "notify"], "コード→1時間使い放題"),
    (["code", "dataCheap", "unl24", "notify"], "コード→データ→使い放題"),
]
for g in GB:
    for acts, aname in LINE_ACTS:
        add("残量ライン",
            f"残り{gbname(g)}を切ったら:{aname}",
            f"Wi-Fi 以外で残りが {gbname(g)} を切ったら、{aname} の順で手を打ちます。",
            {"low": {"kind": "gb", "value": g}, "act": acts, "wifiSkip": True})

# ---- 2. なくなる前に(予測: あと何時間) --------------------------------------
for h in HOURS:
    for acts, aname in LINE_ACTS:
        add("なくなる前に",
            f"あと{h}時間を切りそう:{aname}",
            f"今のペースだと約 {h} 時間以内になくなりそうなら、{aname} の順で補います。",
            {"low": {"kind": "hours", "value": h}, "act": acts, "wifiSkip": True})

# ---- 3. 夜は買わない(0-7時は通知だけ) ---------------------------------------
for g in GB:
    for acts, aname in LINE_ACTS[:5]:
        add("夜は買わない",
            f"残り{gbname(g)}・夜は知らせるだけ:{aname}",
            f"残りが {gbname(g)} を切ったら {aname}。ただし 0〜7 時は買わずに知らせるだけ。",
            {"low": {"kind": "gb", "value": g}, "act": acts, "wifiSkip": True, "night": True})

# ---- 4. 電池を節約(充電していないときは短い使い放題) ------------------------
for g in GB:
    for lvl in [10, 20, 30]:
        add("電池を節約",
            f"残り{gbname(g)}・電池{lvl}%未満は1時間だけ",
            f"残りが {gbname(g)} を切ったら動きます。電池が {lvl}% 未満で充電していなければ 1 時間の使い放題、そうでなければ 24 時間。",
            {"low": {"kind": "gb", "value": g}, "act": ["code", "unlSmart", "notify"],
             "wifiSkip": True, "batteryLow": lvl})

# ---- 5. Wi-Fi 切替を見張る(Wi-Fi が切れた直後だけ動く) ----------------------
for g in GB:
    for acts, aname in LINE_ACTS[:5]:
        add("Wi-Fiが切れたら",
            f"Wi-Fiが切れて残り{gbname(g)}未満:{aname}",
            f"Wi-Fi が切れたときに残りが {gbname(g)} 未満なら {aname}。(ショートカットの wifi-off と相性よし)",
            {"low": {"kind": "gb", "value": g}, "act": acts, "trigger": "wifi-off"})

# ---- 6. 時間帯で変える(朝だけ/日中だけ/夜だけ補充) -------------------------
WINDOWS = [("朝(6-9時)", 6, 9), ("日中(9-18時)", 9, 18), ("夜(18-24時)", 18, 24), ("通勤(7-9,17-20)", 7, 20)]
for wname, a, b in WINDOWS:
    for g in [0.2, 0.3, 0.5, 1.0]:
        add("時間帯で動く",
            f"{wname}だけ補充・残り{gbname(g)}",
            f"{wname} に残りが {gbname(g)} を切ったら、コード→使い放題で補います。ほかの時間は買わずに知らせます(コードは使います)。",
            {"low": {"kind": "gb", "value": g}, "act": ["code", "unlSmart", "notify"],
             "wifiSkip": True, "window": [a, b]})

# ---- 7. 使い放題の見張り(終わりが近いと知らせる/継ぐ) -----------------------
for m in [10, 15, 30, 60]:
    add("使い放題の見張り",
        f"使い放題があと{m}分で終わるぞ",
        f"使い放題の残りが約 {m} 分を切ったら知らせます。",
        {"unlimitedEndingMin": m, "act": ["notify"]})
    add("使い放題の見張り",
        f"使い放題が切れる{m}分前にコードを用意",
        f"使い放題の残りが約 {m} 分を切ったら、手持ちのコードがあれば続けて使い、無ければ知らせます。",
        {"unlimitedEndingMin": m, "act": ["code", "notify"]})

# ---- 8. 旅行・帰省(高め残量を保つ) -----------------------------------------
for g in [1.0, 2.0, 3.0]:
    add("旅行・外出",
        f"外出中は残り{gbname(g)}を保つ",
        f"残りが {gbname(g)} を切ったら、コード→1GBあたり最安のデータ追加で、多めに保ちます。夜は買いません。",
        {"low": {"kind": "gb", "value": g}, "act": ["code", "dataCheap", "notify"],
         "wifiSkip": True, "night": True})

# ---- 9. 使った分だけ(今日の使用量で判断) -----------------------------------
for mb in [500, 1000, 2000, 3000]:
    add("使いすぎを見張る",
        f"今日{mb}MB使ったら知らせる",
        f"今日の使用量が {mb}MB を超えたら知らせます(買いません)。",
        {"usedTodayMB": mb, "act": ["notify"]})

# ---- 10. 知らせるだけ(残量ライン別) ----------------------------------------
for g in GB:
    add("知らせるだけ",
        f"残り{gbname(g)}で知らせる",
        f"残りが {gbname(g)} を切ったら知らせます。買いません・使いません。",
        {"low": {"kind": "gb", "value": g}, "act": ["notify"]})

cats = {}
for r in recipes:
    cats[r["category"]] = cats.get(r["category"], 0) + 1
out = {"recipes": recipes, "categoryOrder": list(dict.fromkeys(r["category"] for r in recipes))}
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, separators=(",", ":"))
print("recipes:", len(recipes))
for c, n in cats.items():
    print(f"  {c}: {n}")
