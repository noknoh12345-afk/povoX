//! povo-core の呼び出しを1か所に集める。モック時は povo へ一切通信しない。
//! (povo-web の backend.rs をそのまま流用。請求書まわりは今は画面から使っていない。)
#![allow(dead_code)]

use std::sync::Arc;

use povo_core::{ActionType, AuthChallenge, PovoClient, PovoError};
use serde::Serialize;
use serde_json::{json, Value};

use crate::{mock, protocol};

/// 画面に返すエラー。povo 側のステータスとコードはそのまま見せる。
#[derive(Debug, Clone, Serialize)]
pub struct Failure {
    pub message: String,
    pub povo_status: Option<u16>,
    pub povo_code: Option<i64>,
    pub hint: Option<String>,
    /// povo が「この時刻まで再試行するな」と返したときのエポックミリ秒。
    pub block_until_ms: Option<i64>,
    /// これ以上 povo に送るのを止めるべきエラーか(403、PIN要求など)。
    pub halt: bool,
}

impl Failure {
    pub fn local(message: impl Into<String>) -> Self {
        Failure { message: message.into(), povo_status: None, povo_code: None, hint: None, block_until_ms: None, halt: false }
    }
}

impl From<PovoError> for Failure {
    fn from(e: PovoError) -> Self {
        match e {
            PovoError::Api { status, server_message, code, title, detail, block_until_epoch_millis } => {
                let text = detail.or(title).unwrap_or(server_message);
                let hint = match (status, code) {
                    (403, Some(403001)) => Some(
                        "端末IDとトークンが一致していません。保存データが壊れている可能性があります。ログアウトして、ログインし直してください。".into(),
                    ),
                    (403, _) => Some("povo に拒否されました。安全のため以降の通信を止めています。".into()),
                    (401, _) => Some("トークンが無効です。期限切れなら次の操作で自動更新されます。続く場合はログインし直してください。".into()),
                    (422, _) => Some("povo が内容を受け付けませんでした(対象外・購入済み・使用済み・期限切れなど)。".into()),
                    (429, _) | (503, _) => Some("povo から待機を求められました。時間をおいてください。".into()),
                    (s, _) if s >= 500 => Some("povo 側のエラーです。このツールは自動で再試行しません。".into()),
                    _ => None,
                };
                Failure {
                    message: text,
                    povo_status: Some(status),
                    povo_code: code,
                    hint,
                    block_until_ms: block_until_epoch_millis,
                    halt: status == 403,
                }
            }
            PovoError::Network(m) => Failure { hint: Some("ネットワークに繋がっているか確認してください。".into()), ..Failure::local(format!("通信エラー: {m}")) },
            PovoError::Decode(m) => Failure::local(format!("povo の応答を読めませんでした: {m}")),
            PovoError::Unauthenticated => Failure::local("ログインしていません。"),
            PovoError::InvalidArgument(m) => Failure::local(format!("引数エラー: {m}")),
        }
    }
}

pub type R<T> = Result<T, Failure>;

#[derive(Clone)]
pub enum Backend {
    Real(Arc<PovoClient>),
    Mock(Arc<std::sync::Mutex<mock::MockState>>),
}

impl Backend {
    /// povo-android の `PovoAccountClient.create` と同じ設定で作る。
    pub fn new(mock: bool, device_id: &str) -> Self {
        Self::with_scenario(mock, device_id, "")
    }

    /// モックの筋書き付き("low" は残りわずかから始める)。
    pub fn with_scenario(mock: bool, device_id: &str, scenario: &str) -> Self {
        if mock {
            return Backend::Mock(Arc::new(std::sync::Mutex::new(mock::MockState::new(scenario))));
        }
        let client = PovoClient::new(device_id.to_string(), protocol::APP_VERSION.to_string());
        client.set_user_agent(protocol::USER_AGENT.to_string());
        Backend::Real(client)
    }

    pub fn restore(&self, token: &str, sin: Option<String>) {
        match self {
            Backend::Real(c) => {
                c.set_auth_token(token.to_string());
                c.set_service_instance_number(sin);
            }
            Backend::Mock(m) => m.lock().unwrap_or_else(|e| e.into_inner()).token = Some(token.to_string()),
        }
    }

    pub fn token(&self) -> Option<String> {
        match self {
            Backend::Real(c) => c.auth_token(),
            Backend::Mock(m) => m.lock().unwrap_or_else(|e| e.into_inner()).token.clone(),
        }
    }

    pub fn sin(&self) -> Option<String> {
        match self {
            Backend::Real(c) => c.service_instance_number(),
            Backend::Mock(_) => Some("MOCK-SIN".into()),
        }
    }

    // ---- ログイン -------------------------------------------------------

    /// 要求される認証ステップ(順番どおり)。CAPTCHA は送らない(povo-android と同じ)。
    pub fn login_actions(&self, email: Option<String>, phone: Option<String>) -> R<Vec<ActionType>> {
        match self {
            Backend::Real(c) => {
                let isd = phone.as_ref().map(|_| protocol::ISD_CODE_JP.to_string());
                let has_email = email.is_some();
                let resp = c.request_login_action(email, isd, phone, None)?;
                let mut actions: Vec<ActionType> = resp.actions.into_iter().map(|a| a.action_type).collect();
                if actions.is_empty() {
                    actions.push(if has_email { ActionType::EmailOtp } else { ActionType::LoginOtp });
                }
                Ok(actions)
            }
            Backend::Mock(_) => Ok(vec![if email.is_some() { ActionType::EmailOtp } else { ActionType::LoginOtp }]),
        }
    }

    /// OTP を送り、auth_id を返す。
    pub fn send_otp(&self, action: ActionType, email: Option<&str>, phone: Option<&str>) -> R<String> {
        match self {
            Backend::Real(c) => {
                let resp = match action {
                    ActionType::EmailOtp => c.send_email_otp(
                        email.ok_or_else(|| Failure::local("メールアドレスが必要です"))?.to_string(),
                    )?,
                    ActionType::LoginOtp | ActionType::RegisterOtp => c.send_mobile_otp(
                        protocol::ISD_CODE_JP.to_string(),
                        phone.ok_or_else(|| Failure::local("この認証には電話番号が必要です"))?.to_string(),
                    )?,
                };
                Ok(resp.auth_id)
            }
            Backend::Mock(_) => Ok("MOCK-AUTH-ID".into()),
        }
    }

    pub fn login(&self, email_auth: Option<AuthChallenge>, mobile_auth: Option<AuthChallenge>) -> R<String> {
        match self {
            Backend::Real(c) => {
                let t = c.login(email_auth, mobile_auth)?;
                if t.pin_token.is_some() {
                    // povo-android と同じく未対応。黙ってトークンを保存しない。
                    c.clear_auth_token();
                    return Err(Failure {
                        halt: true,
                        ..Failure::local("このアカウントはPIN認証を要求しました。このツールは未対応です(povo-android も未対応)。")
                    });
                }
                Ok(t.auth_token)
            }
            Backend::Mock(m) => {
                let code = email_auth.or(mobile_auth).map(|a| a.otp_code).unwrap_or_default();
                if code != "000000" {
                    return Err(Failure { povo_status: Some(400), ..Failure::local("(モック)コードは 000000 です") });
                }
                let t = mock_jwt();
                m.lock().unwrap_or_else(|e| e.into_inner()).token = Some(t.clone());
                Ok(t)
            }
        }
    }

    /// 期限切れのときだけ更新する。更新したら新しいトークンを返す。
    pub fn refresh_if_expired(&self) -> R<Option<String>> {
        let Some(current) = self.token() else {
            return Err(Failure::local("ログインしていません。"));
        };
        if !protocol::is_expired(&current) {
            return Ok(None);
        }
        match self {
            Backend::Real(c) => Ok(Some(c.refresh_token()?.auth_token)),
            Backend::Mock(m) => {
                let t = mock_jwt();
                m.lock().unwrap_or_else(|e| e.into_inner()).token = Some(t.clone());
                Ok(Some(t))
            }
        }
    }

    // ---- 取得 -----------------------------------------------------------

    /// ログイン直後に必ず最初に呼ぶ(回線番号 SIN がここで決まる)。
    pub fn profile(&self) -> R<Value> {
        match self {
            Backend::Real(c) => {
                let p = c.get_profile()?;
                let t = p.telco_info.as_ref();
                Ok(json!({
                    "first_name": p.first_name,
                    "email": p.email,
                    "phone": t.and_then(|t| t.phone_no.clone()),
                    "status": t.and_then(|t| t.status.clone()),
                    "plan": t.and_then(|t| t.billing_info.as_ref()).and_then(|b| b.plan_name.clone()),
                    "activation_date": t.and_then(|t| t.activation_date.clone().or(t.initial_activation_date.clone()))
                        .map(|d| d.chars().take(10).collect::<String>()),
                }))
            }
            Backend::Mock(_) => Ok(json!({
                "first_name": "モック", "email": "mock@example.com", "phone": "09000000000",
                "status": "Active", "plan": "povo2.0", "activation_date": "2024-01-01"
            })),
        }
    }

    pub fn usage_raw(&self) -> R<String> {
        match self {
            Backend::Real(c) => Ok(c.get_plan_usage_json()?),
            Backend::Mock(m) => Ok(m.lock().unwrap_or_else(|e| e.into_inner()).usage_json()),
        }
    }

    /// Quilt ページ(`/api/v1/quilt/page/{page}`)。
    pub fn quilt(&self, page: &str) -> R<String> {
        match self {
            Backend::Real(c) => Ok(c.get_quilt_page_json(page.to_string())?),
            Backend::Mock(m) => {
                let mut m = m.lock().unwrap_or_else(|e| e.into_inner());
                Ok(match page {
                    "user-plan-details-v2" => m.plan_details_json(),
                    "order-history" => m.order_history_json(),
                    "dashboard-v2" => mock::DASHBOARD.into(),
                    _ => "{}".into(),
                })
            }
        }
    }

    pub fn bills_raw(&self) -> R<String> {
        match self {
            Backend::Real(c) => Ok(c.get_json("layout/bills/info".into(), None, "v5".into(), "ja".into())?),
            Backend::Mock(_) => Ok(mock::BILLS.into()),
        }
    }

    /// 友だち紹介コード(`account/referral/code/get`)。
    pub fn referral_raw(&self) -> R<String> {
        match self {
            Backend::Real(c) => Ok(c.get_referral_code_json()?),
            Backend::Mock(_) => Ok(mock::REFERRAL.into()),
        }
    }

    pub fn bill_pdf(&self, bill_id: &str) -> R<Vec<u8>> {
        match self {
            Backend::Real(c) => Ok(c.download_bill_pdf(bill_id.to_string())?),
            Backend::Mock(_) => Ok(mock::bill_pdf()),
        }
    }

    // ---- 購入 -----------------------------------------------------------

    /// `POST /v2/jp/ja/mobile/shop/orders`。body は povo-android と同じ形
    /// (`offer_product` は null を明示して送る)。アカウントはトークンから決まる。
    pub fn place_order(&self, sku: &str) -> R<String> {
        match self {
            Backend::Real(c) => {
                let body = json!({
                    "sku": sku,
                    "offer_product": Value::Null,
                    "redirect_url": protocol::ORDER_REDIRECT_URL,
                });
                Ok(c.post_json("shop/orders".into(), None, "v2".into(), "ja".into(), body.to_string())?)
            }
            Backend::Mock(m) => Ok(m.lock().unwrap_or_else(|e| e.into_inner()).order(sku)?),
        }
    }

    // ---- コード適用 -----------------------------------------------------

    /// プロモコード・プリペイドコードの適用。公式アプリ 1.70.0-JP の
    /// `PromotionsApi.b`(`@FormUrlEncoded @POST("promotions/code/set")`、
    /// `VLI-Version: v4`、`VLI-Localize: true`)と同じ
    /// `POST /v4/jp/ja/mobile/promotions/code/set`、フォーム項目 `code` 1つ。
    /// `uuid` は povo-core がフォームに足す(アプリの UniversalUrlGenerator と同じ)。
    /// 応答は `{codeValid, title, subtitle, message, images[{url}]}`。
    /// 呼ぶ側で、大文字化・前後の空白除去・18文字以内を済ませておくこと(アプリの入力欄と同じ)。
    pub fn apply_code(&self, code: &str) -> R<String> {
        match self {
            Backend::Real(c) => {
                let mut form = std::collections::HashMap::new();
                form.insert("code".to_string(), code.to_string());
                Ok(c.post_form("promotions/code/set".into(), None, "v4".into(), "ja".into(), form)?)
            }
            Backend::Mock(m) => Ok(m.lock().unwrap_or_else(|e| e.into_inner()).apply_code(code)?),
        }
    }
}

/// モック用の、20分で切れるそれらしいJWT。
fn mock_jwt() -> String {
    use base64::Engine;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let enc = |v: Value| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string());
    format!(
        "{}.{}.mock",
        enc(json!({"alg": "none"})),
        enc(json!({"exp": now + 1200, "external_id": "mock-user", "iss": "circles"}))
    )
}
