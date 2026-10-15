import Foundation

/// レシピのパラメータから、ルール(JavaScript の `decide(ctx)`)を組み立てる。
///
/// 使う関数は rule-prelude.js が用意するもの(skip / notify / applyCode / buy / firstOf / cheapest /
/// ctx.catalog())だけ。安全装置(上限・回数・間隔・3DS 除外・1回1つ)はエンジンがかける。
enum RecipeCompiler {
    static func rule(for recipe: Recipe) -> String {
        let p = recipe.params
        var lines: [String] = []
        lines.append("// \(recipe.title)")
        lines.append("// \(recipe.summary)")
        lines.append("// povoX のレシピ (\(recipe.id)) から作成。アプリの「ルール」で自由に書き換えられます。")
        lines.append("function decide(ctx) {")
        lines.append("  const d = ctx.data, f = ctx.forecast;")

        // きっかけのしぼり込み(例: wifi-off のときだけ動く)
        if let t = p.trigger {
            lines.append("  if (ctx.trigger !== \(js(t))) return skip(\(js("対象のきっかけ(\(t))ではない")));")
        }
        // Wi-Fi では何もしない
        if p.wifiSkip {
            lines.append("  if (ctx.network === \"wifi\") return skip(\"Wi-Fi なので何もしない\");")
        }

        // 電池が少ないか(使い放題の長さの判断に使う)
        let blvl = p.batteryLow ?? 20
        lines.append("  const lowBattery = ctx.battery.level != null && ctx.battery.level <= \(blvl) && !ctx.battery.charging;")

        // 「今は買わない時間か」(夜 0-7時 / 指定の時間帯の外)。買い物だけ止め、コードと通知は残す。
        var quietConds: [String] = []
        if p.night { quietConds.append("(ctx.now.hour < 7)") }
        if let w = p.window, w.count == 2 { quietConds.append("!(ctx.now.hour >= \(w[0]) && ctx.now.hour < \(w[1]))") }
        let quiet = quietConds.isEmpty ? "false" : quietConds.joined(separator: " || ")
        lines.append("  const quiet = \(quiet);")

        // 使い放題の終わりが近いか(unlimitedEndingMin)
        if let m = p.unlimitedEndingMin {
            lines.append("  if (d.unlimited.active) {")
            lines.append("    if (d.unlimited.hoursLeft != null && d.unlimited.hoursLeft * 60 <= \(m)) {")
            lines.append("      return \(firstOf(p.act, quietGuarded: false, endingMin: m));")
            lines.append("    }")
            lines.append("    return skip(\"使い放題中(まだ余裕あり)\");")
            lines.append("  }")
            lines.append("  return skip(\"使い放題ではありません\");")
            lines.append("}")
            return lines.joined(separator: "\n") + "\n"
        }

        // 今日の使用量で判断(usedTodayMB)
        if let mb = p.usedTodayMB {
            lines.append("  if (f.usedTodayMB == null) return skip(\"今日の使用量が不明\");")
            lines.append("  if (f.usedTodayMB < \(mb)) return skip(`今日 ${f.usedTodayMB.toFixed(0)}MB`);")
            lines.append("  return \(firstOf(p.act, quietGuarded: false, endingMin: nil));")
            lines.append("}")
            return lines.joined(separator: "\n") + "\n"
        }

        // 残量・予測で判断
        lines.append("  if (d.leftGB == null) return skip(\"残量を読めませんでした\");")
        lines.append("  if (d.unlimited.active) return skip(\"使い放題中\");")

        if let low = p.low {
            if low.kind == "hours" {
                lines.append("  if (f.hoursLeft == null) return skip(\"ペースが読めません\");")
                lines.append("  if (f.hoursLeft >= \(fmt(low.value))) return skip(`このペースなら約 ${f.hoursLeft.toFixed(1)} 時間もちます`);")
            } else {
                lines.append("  if (d.leftGB >= \(fmt(low.value))) return skip(`残り ${d.leftGB.toFixed(2)}GB`);")
            }
        }
        lines.append("  return \(firstOf(p.act, quietGuarded: true, endingMin: nil));")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// やることの並び(firstOf)。quietGuarded のときは、買い物は quiet でないときだけ試す。
    private static func firstOf(_ act: [String], quietGuarded: Bool, endingMin: Int?) -> String {
        var items: [String] = []
        for a in act {
            switch a {
            case "code":
                items.append("applyCode()")
            case "dataCheap":
                items.append(guarded("buy(ctx.catalog().filter(p => !p.unlimited && p.gb != null && p.price != null && !p.requires3ds).sort((a, b) => a.price / a.gb - b.price / b.gb)[0])", quietGuarded))
            case "unl1":
                items.append(guarded("buy(cheapest(ctx.catalog(), p => p.unlimited && p.hours === 1))", quietGuarded))
            case "unl24":
                items.append(guarded("buy(cheapest(ctx.catalog(), p => p.unlimited && p.hours === 24))", quietGuarded))
            case "unlSmart":
                items.append(guarded("buy(cheapest(ctx.catalog(), p => p.unlimited && p.hours === (lowBattery ? 1 : 24)))", quietGuarded))
            case "notify":
                items.append(notify(endingMin: endingMin))
            default:
                break
            }
        }
        if items.isEmpty { items.append(notify(endingMin: endingMin)) }
        return "firstOf(\n    " + items.joined(separator: ",\n    ") + "\n  )"
    }

    /// quiet(夜・時間帯外)のときは買い物を飛ばす(skip)ように包む。
    private static func guarded(_ buyExpr: String, _ on: Bool) -> String {
        on ? "(quiet ? skip(\"今は買わない時間\") : \(buyExpr))" : buyExpr
    }

    private static func notify(endingMin: Int?) -> String {
        if let m = endingMin {
            return "notify(\"povo 使い放題がもうすぐ終わります\", `あと約${Math.round((d.unlimited.hoursLeft || 0) * 60)}分(目安 \(m)分)`)"
        }
        return "notify(\"povo 残りわずか\", `残り ${d.leftMB == null ? \"?\" : d.leftMB.toFixed(0)}MB`)"
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// JS の文字列リテラル(安全に埋め込む)。
    private static func js(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
