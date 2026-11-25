use serde::{Deserialize, Serialize};

use crate::error::ProtocolError;
use crate::frame::{Frame, FrameType};

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Android,
    Ios,
    Linux,
    Macos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VideoProfile {
    Hd,
    FullHd,
    Qhd,
}

impl VideoProfile {
    pub const ALL: [Self; 3] = [Self::Hd, Self::FullHd, Self::Qhd];

    pub fn dimensions(self) -> (u32, u32) {
        match self {
            Self::Hd => (1280, 720),
            Self::FullHd => (1920, 1080),
            Self::Qhd => (2560, 1440),
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Hd => "HD (1280×720)",
            Self::FullHd => "Full HD (1920×1080)",
            Self::Qhd => "2K (2560×1440)",
        }
    }

    pub fn bitrate_range_kbps(self) -> (u32, u32) {
        match self {
            Self::Hd => (2_000, 4_000),
            Self::FullHd => (4_000, 8_000),
            Self::Qhd => (6_000, 12_000),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Facing {
    Front,
    Back,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileAvailability {
    pub profile: VideoProfile,
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityMode {
    pub width: u32,
    pub height: u32,
    pub available: bool,
    pub max_fps: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    PermissionDeniedCamera,
    PermissionDeniedMic,
    LanPermissionDenied,
    ReceiverNotFound,
    PairingExpired,
    AuthFailed,
    UnsupportedResolution,
    CodecIncompatible,
    NetworkInterrupted,
    ThermalLimit,
    TlsFingerprintMismatch,
    UsbTunnelFailed,
    VirtualCameraUnavailable,
    DecoderFailed,
    CommandFailed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all_fields = "camelCase")]
pub enum Message {
    #[serde(rename = "hello")]
    Hello {
        device_name: String,
        platform: Platform,
        app_version: String,
    },
    #[serde(rename = "pair.request")]
    PairRequest { nonce: String },
    #[serde(rename = "pair.confirm")]
    PairConfirm { nonce: String, confirmed: bool },
    #[serde(rename = "pair.denied")]
    PairDenied { reason: String },
    #[serde(rename = "profile.query")]
    ProfileQuery,
    #[serde(rename = "profile.list")]
    ProfileList { profiles: Vec<ProfileAvailability> },
    #[serde(rename = "profile.set")]
    ProfileSet {
        profile: VideoProfile,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        bitrate_kbps: Option<u32>,
    },
    #[serde(rename = "profile.actual")]
    ProfileActual {
        width: u32,
        height: u32,
        fps: u32,
        bitrate_kbps: u32,
        #[serde(default)]
        rotation: u32,
    },
    #[serde(rename = "capabilities")]
    Capabilities {
        modes: Vec<CapabilityMode>,
        fps_options: Vec<u32>,
        facing: Facing,
        can_switch: bool,
        streaming: bool,
    },
    #[serde(rename = "stream.start")]
    StreamStart { width: u32, height: u32, fps: u32 },
    #[serde(rename = "stream.stop")]
    StreamStop,
    #[serde(rename = "fps.set")]
    FpsSet { fps: u32 },
    #[serde(rename = "audio.set")]
    AudioSet { enabled: bool },
    #[serde(rename = "camera.switch")]
    CameraSwitch {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        facing: Option<Facing>,
    },
    #[serde(rename = "keyframe.request")]
    KeyframeRequest,
    #[serde(rename = "stats")]
    Stats {
        fps: f32,
        bitrate_kbps: u32,
        dropped_frames: u64,
        queue_ms: u32,
    },
    #[serde(rename = "heartbeat")]
    Heartbeat,
    #[serde(rename = "session.stop")]
    SessionStop,
    #[serde(rename = "error")]
    Error { code: ErrorCode, message: String },
}

#[derive(Serialize)]
struct EnvelopeOut<'a> {
    #[serde(rename = "protocolVersion")]
    protocol_version: u32,
    #[serde(flatten)]
    message: &'a Message,
}

#[derive(Deserialize)]
struct VersionProbe {
    #[serde(rename = "protocolVersion")]
    protocol_version: u32,
}

#[derive(Deserialize)]
struct EnvelopeIn {
    #[serde(flatten)]
    message: Message,
}

impl Message {
    pub fn to_json(&self) -> Result<Vec<u8>, ProtocolError> {
        Ok(serde_json::to_vec(&EnvelopeOut {
            protocol_version: PROTOCOL_VERSION,
            message: self,
        })?)
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self, ProtocolError> {
        let probe: VersionProbe = serde_json::from_slice(bytes)?;
        if probe.protocol_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(probe.protocol_version));
        }
        Ok(serde_json::from_slice::<EnvelopeIn>(bytes)?.message)
    }

    pub fn to_frame(&self, pts_us: u64) -> Result<Frame, ProtocolError> {
        Ok(Frame::new(FrameType::Control, 0, pts_us, self.to_json()?))
    }

    pub fn from_frame(frame: &Frame) -> Result<Self, ProtocolError> {
        if frame.kind != FrameType::Control {
            return Err(ProtocolError::NotControl(frame.kind));
        }
        Self::from_json(&frame.payload)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn todas() -> Vec<Message> {
        vec![
            Message::Hello {
                device_name: "Pixel".into(),
                platform: Platform::Android,
                app_version: "0.1.0".into(),
            },
            Message::PairRequest {
                nonce: "ab12".into(),
            },
            Message::PairConfirm {
                nonce: "ab12".into(),
                confirmed: true,
            },
            Message::PairDenied {
                reason: "expirou".into(),
            },
            Message::ProfileQuery,
            Message::ProfileList {
                profiles: vec![
                    ProfileAvailability {
                        profile: VideoProfile::Hd,
                        available: true,
                        reason: None,
                    },
                    ProfileAvailability {
                        profile: VideoProfile::Qhd,
                        available: false,
                        reason: Some("o encoder não chega a 1440p".into()),
                    },
                ],
            },
            Message::ProfileSet {
                profile: VideoProfile::FullHd,
                bitrate_kbps: Some(6000),
            },
            Message::ProfileActual {
                width: 1920,
                height: 1080,
                fps: 30,
                bitrate_kbps: 5800,
                rotation: 90,
            },
            Message::Capabilities {
                modes: vec![
                    CapabilityMode {
                        width: 1920,
                        height: 1080,
                        available: true,
                        max_fps: 30,
                        reason: None,
                    },
                    CapabilityMode {
                        width: 2560,
                        height: 1440,
                        available: false,
                        max_fps: 30,
                        reason: Some("sem codificador".into()),
                    },
                ],
                fps_options: vec![15, 30],
                facing: Facing::Back,
                can_switch: true,
                streaming: false,
            },
            Message::StreamStart {
                width: 1920,
                height: 1080,
                fps: 30,
            },
            Message::StreamStop,
            Message::FpsSet { fps: 15 },
            Message::AudioSet { enabled: false },
            Message::CameraSwitch {
                facing: Some(Facing::Front),
            },
            Message::KeyframeRequest,
            Message::Stats {
                fps: 29.5,
                bitrate_kbps: 5800,
                dropped_frames: 2,
                queue_ms: 40,
            },
            Message::Heartbeat,
            Message::SessionStop,
            Message::Error {
                code: ErrorCode::ThermalLimit,
                message: "aparelho quente".into(),
            },
        ]
    }

    #[test]
    fn toda_mensagem_faz_roundtrip_por_frame() {
        for original in todas() {
            let frame = original.to_frame(1).unwrap();
            let lida = Message::from_frame(&frame).unwrap();
            assert_eq!(lida, original);
        }
    }

    #[test]
    fn json_usa_nomes_do_protocolo() {
        let json = Message::PairRequest { nonce: "ff".into() }
            .to_json()
            .unwrap();
        let texto = String::from_utf8(json).unwrap();
        assert!(texto.contains(r#""protocolVersion":1"#), "{texto}");
        assert!(texto.contains(r#""type":"pair.request""#), "{texto}");

        let json = Message::ProfileActual {
            width: 1,
            height: 2,
            fps: 3,
            bitrate_kbps: 4,
            rotation: 270,
        }
        .to_json()
        .unwrap();
        assert!(
            String::from_utf8(json)
                .unwrap()
                .contains(r#""bitrateKbps":4"#)
        );
    }

    #[test]
    fn codigos_de_erro_em_caixa_alta() {
        let json = Message::Error {
            code: ErrorCode::TlsFingerprintMismatch,
            message: String::new(),
        }
        .to_json()
        .unwrap();
        assert!(
            String::from_utf8(json)
                .unwrap()
                .contains("TLS_FINGERPRINT_MISMATCH")
        );
    }

    #[test]
    fn comandos_novos_usam_nomes_do_protocolo() {
        let texto = |m: Message| String::from_utf8(m.to_json().unwrap()).unwrap();
        assert!(texto(Message::StreamStop).contains(r#""type":"stream.stop""#));
        assert!(
            texto(Message::StreamStart {
                width: 1,
                height: 2,
                fps: 3
            })
            .contains(r#""type":"stream.start""#)
        );
        let caps = texto(Message::Capabilities {
            modes: vec![],
            fps_options: vec![30],
            facing: Facing::Front,
            can_switch: true,
            streaming: true,
        });
        assert!(caps.contains(r#""fpsOptions":[30]"#), "{caps}");
        assert!(caps.contains(r#""canSwitch":true"#), "{caps}");
        assert!(caps.contains(r#""facing":"front""#), "{caps}");
    }

    #[test]
    fn versao_diferente_e_recusada() {
        let err = Message::from_json(br#"{"protocolVersion":2,"type":"heartbeat"}"#).unwrap_err();
        assert!(matches!(err, ProtocolError::UnsupportedVersion(2)));
    }

    #[test]
    fn sem_versao_e_invalido() {
        let err = Message::from_json(br#"{"type":"heartbeat"}"#).unwrap_err();
        assert!(matches!(err, ProtocolError::InvalidControl(_)));
    }

    #[test]
    fn tipo_desconhecido_e_invalido() {
        let err = Message::from_json(br#"{"protocolVersion":1,"type":"nao.existe"}"#).unwrap_err();
        assert!(matches!(err, ProtocolError::InvalidControl(_)));
    }

    #[test]
    fn campo_obrigatorio_ausente_e_invalido() {
        let err = Message::from_json(br#"{"protocolVersion":1,"type":"audio.set"}"#).unwrap_err();
        assert!(matches!(err, ProtocolError::InvalidControl(_)));
    }

    #[test]
    fn json_malformado_nao_causa_panico() {
        for entrada in [
            &b""[..],
            b"{",
            b"null",
            b"[]",
            b"\xff\xfe",
            b"{\"protocolVersion\":",
        ] {
            assert!(Message::from_json(entrada).is_err());
        }
    }

    #[test]
    fn frame_que_nao_e_controle_e_recusado() {
        let frame = Frame::new(FrameType::Video, 0, 0, vec![]);
        assert!(matches!(
            Message::from_frame(&frame).unwrap_err(),
            ProtocolError::NotControl(FrameType::Video)
        ));
    }

    #[test]
    fn profile_actual_sem_rotation_vale_zero() {
        let json = br#"{"protocolVersion":1,"type":"profile.actual","width":1280,"height":720,"fps":30,"bitrateKbps":3000}"#;
        let Message::ProfileActual { rotation, .. } = Message::from_json(json).unwrap() else {
            panic!("não é profile.actual");
        };
        assert_eq!(rotation, 0);
    }

    #[test]
    fn perfis_tem_dimensoes_e_rotulos_esperados() {
        assert_eq!(VideoProfile::Hd.dimensions(), (1280, 720));
        assert_eq!(VideoProfile::FullHd.dimensions(), (1920, 1080));
        assert_eq!(VideoProfile::Qhd.dimensions(), (2560, 1440));
        assert_eq!(VideoProfile::Qhd.label(), "2K (2560×1440)");
        for perfil in VideoProfile::ALL {
            let (min, max) = perfil.bitrate_range_kbps();
            assert!(min < max);
        }
    }
}
