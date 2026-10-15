// povoX の Rust 側(core/)への入口。要求・応答は JSON 文字列(詳細は core/src/lib.rs)。
#ifndef POVO_AUTO_H
#define POVO_AUTO_H

#ifdef __cplusplus
extern "C" {
#endif

/// 戻り値は必ず povo_auto_free で解放する。
char *povo_auto_call(const char *request_json);
void povo_auto_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
