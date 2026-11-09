//! API que o Flutter chama. Os tipos são planos de propósito (sem enums com dados): assim a
//! ponte não precisa do `freezed` nem do `build_runner` no lado do Dart.

use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use cdc_core::{
    Canvas, Device, DeviceEvent, Discovery, OutputSize as CoreSize, SessionEvent, SessionOptions,
    Sink, StopHandle,
};

use crate::frb_generated::StreamSink;

/// Um celular achado na rede.
#[derive(Clone)]
pub struct PhoneInfo {
    pub id: String,
    pub name: String,
    pub host: String,
    /// `ip:porta` para conectar, ou `None` se o celular não anunciou um IPv4 utilizável.
    pub address: Option<String>,
    pub port: u16,
    /// `true` quando o celular saiu da rede; nesse caso só `id` vale.
    pub lost: bool,
    /// Se a busca não pôde começar ou parou, o motivo; nesse caso só este campo vale.
    ///
    /// Os erros viajam no fluxo e não como `Err`: a ponte entrega o `Err` de uma função com
    /// fluxo num `Future` interno que ninguém escuta, e ele viraria uma exceção solta.
    pub error: Option<String>,
}

impl PhoneInfo {
    fn failure(message: String) -> Self {
        PhoneInfo {
            id: String::new(),
            name: String::new(),
            host: String::new(),
            address: None,
            port: 0,
            lost: false,
            error: Some(message),
        }
    }
}

impl From<Device> for PhoneInfo {
    fn from(d: Device) -> Self {
        PhoneInfo {
            address: d.address(),
            id: d.id,
            name: d.name,
            host: d.host,
            port: d.port,
            lost: false,
            error: None,
        }
    }
}

static DISCOVERY: Mutex<Option<Discovery>> = Mutex::new(None);

/// Começa a procurar celulares. Cada aparição e cada saída chegam em `updates`; se a busca
/// não puder começar, chega um item com `error`.
pub fn start_discovery(updates: StreamSink<PhoneInfo>) {
    stop_discovery();
    let for_events = updates.clone();
    let started = Discovery::start(move |evento| {
        let info = match evento {
            DeviceEvent::Found(d) => d.into(),
            DeviceEvent::Lost { id } => PhoneInfo {
                id,
                name: String::new(),
                host: String::new(),
                address: None,
                port: 0,
                lost: true,
                error: None,
            },
        };
        let _ = for_events.add(info);
    });
    match started {
        Ok(discovery) => {
            if let Ok(mut guard) = DISCOVERY.lock() {
                *guard = Some(discovery);
            }
        }
        Err(e) => {
            let _ = updates.add(PhoneInfo::failure(e.to_string()));
        }
    }
}

/// Para a busca.
pub fn stop_discovery() {
    if let Ok(mut guard) = DISCOVERY.lock() {
        *guard = None;
    }
}

/// Que tipo de coisa um [`ReceiverEvent`] descreve. Só os campos daquele tipo valem.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiverEventKind {
    /// O celular se apresentou: `text` = nome, `text2` = sistema.
    Hello,
    /// O que o celular entrega: `width`, `height`, `fps`, `bitrate_kbps`, `rotation`.
    Profile,
    /// A saída de vídeo (re)iniciou: `canvas_width`, `canvas_height`, `rotation` e, em
    /// `text`, o dispositivo em que escreve (vazio se nenhum).
    Output,
    /// Estatísticas do último segundo: `stats_*` e `frames`.
    Stats,
    /// Um quadro JPEG da prévia: `preview`.
    Preview,
    /// O celular reportou um erro: `text` = código, `text2` = mensagem.
    SenderError,
    /// Aviso que não interrompe: `text`.
    Notice,
    /// A sessão terminou normalmente.
    Ended,
    /// A sessão terminou por erro: `text` = explicação.
    Failed,
}

pub struct ReceiverEvent {
    pub kind: ReceiverEventKind,
    pub text: String,
    pub text2: String,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate_kbps: u32,
    pub rotation: u32,
    pub canvas_width: u32,
    pub canvas_height: u32,
    pub stats_fps: f64,
    pub stats_kbps: f64,
    pub stats_delay_ms: f64,
    pub frames: u64,
    /// Bytes de um quadro JPEG, só no evento `Preview`.
    pub preview: Vec<u8>,
}

impl ReceiverEvent {
    fn new(kind: ReceiverEventKind) -> Self {
        Self {
            kind,
            text: String::new(),
            text2: String::new(),
            width: 0,
            height: 0,
            fps: 0,
            bitrate_kbps: 0,
            rotation: 0,
            canvas_width: 0,
            canvas_height: 0,
            stats_fps: 0.0,
            stats_kbps: 0.0,
            stats_delay_ms: 0.0,
            frames: 0,
            preview: Vec::new(),
        }
    }
}

impl From<SessionEvent> for ReceiverEvent {
    fn from(e: SessionEvent) -> Self {
        match e {
            SessionEvent::Hello {
                device_name,
                platform,
            } => Self {
                text: device_name,
                text2: platform,
                ..Self::new(ReceiverEventKind::Hello)
            },
            SessionEvent::Profile {
                width,
                height,
                fps,
                bitrate_kbps,
                rotation,
            } => Self {
                width,
                height,
                fps,
                bitrate_kbps,
                rotation,
                ..Self::new(ReceiverEventKind::Profile)
            },
            SessionEvent::Output {
                canvas_width,
                canvas_height,
                rotation,
                device,
            } => Self {
                canvas_width,
                canvas_height,
                rotation,
                text: device.unwrap_or_default(),
                ..Self::new(ReceiverEventKind::Output)
            },
            SessionEvent::Stats(s) => Self {
                stats_fps: s.fps,
                stats_kbps: s.kbps,
                stats_delay_ms: s.delay_ms,
                frames: s.frames,
                ..Self::new(ReceiverEventKind::Stats)
            },
            SessionEvent::Preview(jpeg) => Self {
                preview: jpeg,
                ..Self::new(ReceiverEventKind::Preview)
            },
            SessionEvent::SenderError { code, message } => Self {
                text: code,
                text2: message,
                ..Self::new(ReceiverEventKind::SenderError)
            },
            SessionEvent::Notice(texto) => Self {
                text: texto,
                ..Self::new(ReceiverEventKind::Notice)
            },
        }
    }
}

/// Formato do quadro entregue à webcam virtual.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    /// Vertical se o celular estiver em pé ao conectar, horizontal se estiver deitado.
    Auto,
    Horizontal,
    Vertical,
}

impl From<OutputFormat> for Canvas {
    fn from(f: OutputFormat) -> Self {
        match f {
            OutputFormat::Auto => Canvas::Auto,
            OutputFormat::Horizontal => Canvas::Horizontal,
            OutputFormat::Vertical => Canvas::Vertical,
        }
    }
}

/// Tamanho do quadro entregue à webcam virtual. Não acompanha a resolução do celular.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputSize {
    Hd,
    FullHd,
    Qhd,
}

impl From<OutputSize> for CoreSize {
    fn from(s: OutputSize) -> Self {
        match s {
            OutputSize::Hd => CoreSize::Hd,
            OutputSize::FullHd => CoreSize::FullHd,
            OutputSize::Qhd => CoreSize::Qhd,
        }
    }
}

/// Uma webcam virtual de tamanho fixo, para um tamanho e um formato.
pub struct ShapeDevice {
    pub size: OutputSize,
    /// `true` para vertical, `false` para horizontal.
    pub vertical: bool,
    pub path: String,
}

static SESSION: Mutex<Option<StopHandle>> = Mutex::new(None);

/// Conecta a um celular e entrega o vídeo à webcam virtual `v4l2_device` (sem ela, só mede).
/// Os eventos chegam em `events` até a sessão terminar, e o último é sempre `Ended` ou
/// `Failed`: inclusive quando a conexão nem abre ou já há uma sessão.
pub fn connect_phone(
    address: String,
    v4l2_device: Option<String>,
    format: OutputFormat,
    size: OutputSize,
    shape_devices: Vec<ShapeDevice>,
    preview: bool,
    events: StreamSink<ReceiverEvent>,
) {
    let fail = |text: String| {
        let _ = events.add(ReceiverEvent {
            text,
            ..ReceiverEvent::new(ReceiverEventKind::Failed)
        });
    };
    let stop = StopHandle::new();
    match SESSION.lock() {
        Ok(mut guard) => {
            if guard.as_ref().is_some_and(|s| !s.is_stopped()) {
                return fail("já existe uma sessão em andamento".into());
            }
            *guard = Some(stop.clone());
        }
        Err(_) => return fail("estado interno corrompido".into()),
    }
    let stream = match cdc_core::connect(&address, Duration::from_secs(5)) {
        Ok(s) => s,
        Err(e) => {
            clear_session(&stop);
            return fail(e.to_string());
        }
    };
    let options = SessionOptions {
        sink: Sink {
            v4l2: v4l2_device,
            dump: None,
        },
        canvas: format.into(),
        output_size: size.into(),
        shape_devices: shape_devices
            .into_iter()
            .map(|d| cdc_core::ShapeDevice {
                size: d.size.into(),
                canvas: if d.vertical {
                    Canvas::Vertical
                } else {
                    Canvas::Horizontal
                },
                path: d.path,
            })
            .collect(),
        device_name: computer_name(),
        preview,
        ..SessionOptions::default()
    };
    thread::spawn(move || {
        let resultado = cdc_core::run(stream, &options, &stop, |e| {
            let _ = events.add(e.into());
        });
        let final_event = match resultado {
            Ok(_) => ReceiverEvent::new(ReceiverEventKind::Ended),
            Err(e) => ReceiverEvent {
                text: e.to_string(),
                ..ReceiverEvent::new(ReceiverEventKind::Failed)
            },
        };
        let _ = events.add(final_event);
        clear_session(&stop);
    });
}

fn clear_session(stop: &StopHandle) {
    if let Ok(mut guard) = SESSION.lock() {
        *guard = None;
    }
    stop.stop();
}

/// Encerra a sessão em andamento, se houver.
pub fn disconnect_phone() {
    if let Ok(guard) = SESSION.lock()
        && let Some(stop) = guard.as_ref()
    {
        stop.stop();
    }
}

/// `true` se o `ffmpeg` está instalado: sem ele não há como escrever na webcam virtual.
pub fn ffmpeg_available() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Nome deste computador, que o celular mostra.
pub fn computer_name() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "computador".into())
}
